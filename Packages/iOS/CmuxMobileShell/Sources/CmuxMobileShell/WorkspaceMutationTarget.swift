import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel

/// Routing target for a workspace mutation in the aggregated multi-Mac list.
struct WorkspaceMutationTarget {
    let client: MobileCoreRPCClient?
    let isForeground: Bool
    let macDeviceID: String?
}

/// Snapshot of an optimistically-removed workspace, used to restore the row at its
/// original position (`macKey`/`index`) when a backend close cannot be delivered.
/// `previousSelection` / `autoSelection` let the rollback also undo the selection
/// move the removal triggered, without clobbering a selection the user changed
/// while the close was in flight.
struct WorkspaceCloseRollback {
    let macKey: String
    let index: Int
    let workspace: MobileWorkspacePreview
    /// The selected workspace id before the optimistic removal.
    let previousSelection: MobileWorkspacePreview.ID?
    /// The selected workspace id right after the removal (the neighbor selection
    /// reconciliation auto-picked), used to detect intervening user selection.
    let autoSelection: MobileWorkspacePreview.ID?
}
