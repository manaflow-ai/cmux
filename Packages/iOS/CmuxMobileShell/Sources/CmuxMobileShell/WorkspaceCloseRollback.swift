import CmuxMobileShellModel

/// Snapshot of an optimistically-removed workspace, used to restore the row near
/// its original position when a backend close cannot be delivered.
///
/// Restoration anchors to a still-present neighbor (`precedingID`, then
/// `followingID`) rather than the raw integer `index`, so several optimistic closes
/// that fail out of order do not reorder the surviving rows; `index` is only a
/// last-resort fallback when both neighbors are also gone. `previousSelection` /
/// `autoSelection` let the rollback also undo the selection move the removal
/// triggered, without clobbering a selection the user changed while the close was
/// in flight.
struct WorkspaceCloseRollback {
    let macKey: String
    /// The removed row's original position in the owning Mac's array (fallback only).
    let index: Int
    let workspace: MobileWorkspacePreview
    /// `rpcWorkspaceID` of the row immediately before the removed one (nil = it was
    /// first); restoration re-inserts right after this row when it is still present.
    let precedingID: MobileWorkspacePreview.ID?
    /// `rpcWorkspaceID` of the row immediately after the removed one (nil = it was
    /// last); restoration re-inserts right before this row when the preceding row is
    /// gone but this one survives.
    let followingID: MobileWorkspacePreview.ID?
    /// The selected workspace id before the optimistic removal.
    let previousSelection: MobileWorkspacePreview.ID?
    /// The selected workspace id right after the removal (the neighbor selection
    /// reconciliation auto-picked), used to detect intervening user selection.
    let autoSelection: MobileWorkspacePreview.ID?
}
