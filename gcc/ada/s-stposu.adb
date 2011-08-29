------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--        S Y S T E M . S T O R A G E _ P O O L S . S U B P O O L S         --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--            Copyright (C) 2011, Free Software Foundation, Inc.            --
--                                                                          --
-- This specification is derived from the Ada Reference Manual for use with --
-- GNAT. The copyright notice above, and the license provisions that follow --
-- apply solely to the  contents of the part following the private keyword. --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.                                     --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
-- GNAT was originally developed  by the GNAT team at  New York University. --
-- Extensive contributions were provided by Ada Core Technologies Inc.      --
--                                                                          --
------------------------------------------------------------------------------

with Ada.Exceptions;              use Ada.Exceptions;
with Ada.Unchecked_Deallocation;

with System.Finalization_Masters; use System.Finalization_Masters;
with System.Soft_Links;           use System.Soft_Links;
with System.Storage_Elements;     use System.Storage_Elements;

package body System.Storage_Pools.Subpools is

   procedure Attach (N : not null SP_Node_Ptr; L : not null SP_Node_Ptr);
   --  Attach a subpool node to a pool

   procedure Free is new Ada.Unchecked_Deallocation (SP_Node, SP_Node_Ptr);

   procedure Detach (N : not null SP_Node_Ptr);
   --  Unhook a subpool node from an arbitrary subpool list

   --------------
   -- Allocate --
   --------------

   overriding procedure Allocate
     (Pool                     : in out Root_Storage_Pool_With_Subpools;
      Storage_Address          : out System.Address;
      Size_In_Storage_Elements : System.Storage_Elements.Storage_Count;
      Alignment                : System.Storage_Elements.Storage_Count)
   is
   begin
      --  ??? The use of Allocate is very dangerous as it does not handle
      --  controlled objects properly. Perhaps we should provide an
      --  implementation which raises Program_Error instead.

      --  Dispatch to the user-defined implementations of Allocate_From_Subpool
      --  and Default_Subpool_For_Pool.

      Allocate_From_Subpool
        (Root_Storage_Pool_With_Subpools'Class (Pool),
         Storage_Address,
         Size_In_Storage_Elements,
         Alignment,
         Default_Subpool_For_Pool
           (Root_Storage_Pool_With_Subpools'Class (Pool)));
   end Allocate;

   -----------------------------
   -- Allocate_Any_Controlled --
   -----------------------------

   procedure Allocate_Any_Controlled
     (Pool            : in out Root_Storage_Pool'Class;
      Context_Subpool : Subpool_Handle := null;
      Context_Master  : Finalization_Masters.Finalization_Master_Ptr := null;
      Fin_Address     : Finalization_Masters.Finalize_Address_Ptr := null;
      Addr            : out System.Address;
      Storage_Size    : System.Storage_Elements.Storage_Count;
      Alignment       : System.Storage_Elements.Storage_Count;
      Is_Controlled   : Boolean := True)
   is
      --  ??? This membership test gives the wrong result when Pool has
      --  subpools.

      Is_Subpool_Allocation : constant Boolean :=
                                Pool in Root_Storage_Pool_With_Subpools;

      Master  : Finalization_Master_Ptr := null;
      N_Addr  : Address;
      N_Ptr   : FM_Node_Ptr;
      N_Size  : Storage_Count;
      Subpool : Subpool_Handle := null;

   begin
      --  Step 1: Pool-related runtime checks

      --  Allocation on a pool_with_subpools. In this scenario there is a
      --  master for each subpool.

      if Is_Subpool_Allocation then

         --  Case of an allocation without a Subpool_Handle. Dispatch to the
         --  implementation of Default_Subpool_For_Pool.

         if Context_Subpool = null then
            Subpool :=
              Default_Subpool_For_Pool
                (Root_Storage_Pool_With_Subpools'Class (Pool));

            --  Ensure proper ownership

            if Subpool.Owner /=
                 Root_Storage_Pool_With_Subpools'Class (Pool)'Unchecked_Access
            then
               raise Program_Error with "incorrect owner of default subpool";
            end if;

         --  Allocation with a Subpool_Handle

         else
            Subpool := Context_Subpool;

            --  Ensure proper ownership

            if Subpool.Owner /=
                 Root_Storage_Pool_With_Subpools'Class (Pool)'Unchecked_Access
            then
               raise Program_Error with "incorrect owner of subpool";
            end if;
         end if;

         Master := Subpool.Master'Unchecked_Access;

      --  Allocation on a simple pool. In this scenario there is a master for
      --  each access-to-controlled type. No context subpool should be present.

      else

         --  If the master is missing, then the expansion of the access type
         --  failed to create one. This is a serious error.

         if Context_Master = null then
            raise Program_Error with "missing master in pool allocation";

         --  If a subpool is present, then this is the result of erroneous
         --  allocator expansion. This is not a serious error, but it should
         --  still be detected.

         elsif Context_Subpool /= null then
            raise Program_Error with "subpool not required in pool allocation";
         end if;

         Master := Context_Master;
      end if;

      --  Step 2: Master-related runtime checks

      --  Allocation of a descendant from [Limited_]Controlled, a class-wide
      --  object or a record with controlled components.

      if Is_Controlled then

         --  Do not allow the allocation of controlled objects while the
         --  associated master is being finalized.

         if Master.Finalization_Started then
            raise Program_Error with "allocation after finalization started";
         end if;

         --  The size must acount for the hidden header preceding the object

         N_Size := Storage_Size + Header_Size;

      --  Non-controlled allocation

      else
         N_Size := Storage_Size;
      end if;

      --  Step 3: Allocation of object

      --  For descendants of Root_Storage_Pool_With_Subpools, dispatch to the
      --  implementation of Allocate_From_Subpool.

      if Is_Subpool_Allocation then
         Allocate_From_Subpool
           (Root_Storage_Pool_With_Subpools'Class (Pool),
            N_Addr, N_Size, Alignment, Subpool);

      --  For descendants of Root_Storage_Pool, dispatch to the implementation
      --  of Allocate.

      else
         Allocate (Pool, N_Addr, N_Size, Alignment);
      end if;

      --  Step 4: Attachment

      if Is_Controlled then

         --  Map the allocated memory into a FM_Node record. This converts the
         --  top of the allocated bits into a list header.

         N_Ptr := Address_To_FM_Node_Ptr (N_Addr);

         --  Check whether primitive Finalize_Address is available. If it is
         --  not, then either the expansion of the designated type failed or
         --  the expansion of the allocator failed. This is a serious error.

         if Fin_Address = null then
            raise Program_Error
              with "primitive Finalize_Address not available";
         end if;

         N_Ptr.Finalize_Address := Fin_Address;

         --  Prepend the allocated object to the finalization master

         Attach (N_Ptr, Master.Objects'Unchecked_Access);

         --  Move the address from the hidden list header to the start of the
         --  object. This operation effectively hides the list header.

         Addr := N_Addr + Header_Offset;
      else
         Addr := N_Addr;
      end if;
   end Allocate_Any_Controlled;

   ------------
   -- Attach --
   ------------

   procedure Attach (N : not null SP_Node_Ptr; L : not null SP_Node_Ptr) is
   begin
      Lock_Task.all;

      L.Next.Prev := N;
      N.Next := L.Next;
      L.Next := N;
      N.Prev := L;

      Unlock_Task.all;

      --  Note: No need to unlock in case of an exception because the above
      --  code can never raise one.
   end Attach;

   -------------------------------
   -- Deallocate_Any_Controlled --
   -------------------------------

   procedure Deallocate_Any_Controlled
     (Pool          : in out Root_Storage_Pool'Class;
      Addr          : System.Address;
      Storage_Size  : System.Storage_Elements.Storage_Count;
      Alignment     : System.Storage_Elements.Storage_Count;
      Is_Controlled : Boolean := True)
   is
      N_Addr : Address;
      N_Ptr  : FM_Node_Ptr;
      N_Size : Storage_Count;

   begin
      --  Step 1: Detachment

      if Is_Controlled then

         --  Move the address from the object to the beginning of the list
         --  header.

         N_Addr := Addr - Header_Offset;

         --  Convert the bits preceding the object into a list header

         N_Ptr := Address_To_FM_Node_Ptr (N_Addr);

         --  Detach the object from the related finalization master. This
         --  action does not need to know the prior context used during
         --  allocation.

         Detach (N_Ptr);

         --  The size of the deallocated object must include the size of the
         --  hidden list header.

         N_Size := Storage_Size + Header_Size;
      else
         N_Addr := Addr;
         N_Size := Storage_Size;
      end if;

      --  Step 2: Deallocation

      --  Dispatch to the proper implementation of Deallocate. This action
      --  covers both Root_Storage_Pool and Root_Storage_Pool_With_Subpools
      --  implementations.

      Deallocate (Pool, N_Addr, N_Size, Alignment);
   end Deallocate_Any_Controlled;

   ------------
   -- Detach --
   ------------

   procedure Detach (N : not null SP_Node_Ptr) is
   begin
      --  N must be attached to some list

      pragma Assert (N.Next /= null and then N.Prev /= null);

      Lock_Task.all;

      N.Prev.Next := N.Next;
      N.Next.Prev := N.Prev;

      Unlock_Task.all;

      --  Note: No need to unlock in case of an exception because the above
      --  code can never raise one.
   end Detach;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize
     (Pool : in out Root_Storage_Pool_With_Subpools)
   is
      Curr_Ptr : SP_Node_Ptr;
      Ex_Occur : Exception_Occurrence;
      Next_Ptr : SP_Node_Ptr;
      Raised   : Boolean := False;

   begin
      --  Uninitialized pools do not have subpools and do not contain objects
      --  of any kind.

      if not Pool.Initialized then
         return;
      end if;

      --  It is possible for multiple tasks to cause the finalization of a
      --  common pool. Allow only one task to finalize the contents.

      if Pool.Finalization_Started then
         return;
      end if;

      --  Lock the pool to prevent the creation of additional subpools while
      --  the available ones are finalized. The pool remains locked because
      --  either it is about to be deallocated or the associated access type
      --  is about to go out of scope.

      Pool.Finalization_Started := True;

      --  Skip the dummy head

      Curr_Ptr := Pool.Subpools.Next;
      while Curr_Ptr /= Pool.Subpools'Unchecked_Access loop
         Next_Ptr := Curr_Ptr.Next;

         --  Remove the subpool node from the subpool list

         Detach (Curr_Ptr);

         --  Finalize the current subpool

         begin
            Finalize_Subpool (Curr_Ptr.Subpool);

         exception
            when Fin_Occur : others =>
               if not Raised then
                  Raised := True;
                  Save_Occurrence (Ex_Occur, Fin_Occur);
               end if;
         end;

         --  Since subpool nodes are not allocated on the owner pool, they must
         --  be explicitly destroyed.

         Free (Curr_Ptr);

         Curr_Ptr := Next_Ptr;
      end loop;

      --  If the finalization of a particular master failed, reraise the
      --  exception now.

      if Raised then
         Reraise_Occurrence (Ex_Occur);
      end if;
   end Finalize;

   ----------------------
   -- Finalize_Subpool --
   ----------------------

   procedure Finalize_Subpool (Subpool : not null Subpool_Handle) is
   begin
      Finalize (Subpool.Master);
   end Finalize_Subpool;

   ---------------------
   -- Pool_Of_Subpool --
   ---------------------

   function Pool_Of_Subpool (Subpool : not null Subpool_Handle)
     return access Root_Storage_Pool_With_Subpools'Class is
   begin
      return Subpool.Owner;
   end Pool_Of_Subpool;

   -------------------------
   -- Set_Pool_Of_Subpool --
   -------------------------

   procedure Set_Pool_Of_Subpool
     (Subpool : not null Subpool_Handle;
      Pool    : in out Root_Storage_Pool_With_Subpools'Class)
   is
      N_Ptr : SP_Node_Ptr;

   begin
      if not Pool.Initialized then

         --  The dummy head must point to itself in both directions

         Pool.Subpools.Next := Pool.Subpools'Unchecked_Access;
         Pool.Subpools.Prev := Pool.Subpools'Unchecked_Access;
         Pool.Initialized   := True;
      end if;

      --  If the subpool is already owned, raise Program_Error. This is a
      --  direct violation of the RM rules.

      if Subpool.Owner /= null then
         raise Program_Error with "subpool already belongs to a pool";
      end if;

      --  Prevent the creation of a new subpool while the owner is being
      --  finalized. This is a serious error.

      if Pool.Finalization_Started then
         raise Program_Error
           with "subpool creation after finalization started";
      end if;

      --  Create a subpool node, decorate it and associate it with the subpool
      --  list of Pool.

      N_Ptr := new SP_Node;

      Subpool.Owner := Pool'Unchecked_Access;
      N_Ptr.Subpool := Subpool;

      Attach (N_Ptr, Pool.Subpools'Unchecked_Access);
   end Set_Pool_Of_Subpool;

end System.Storage_Pools.Subpools;
