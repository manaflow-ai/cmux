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
struct WorkspaceCloseRollback {
    let macKey: String
    let index: Int
    let workspace: MobileWorkspacePreview
}
