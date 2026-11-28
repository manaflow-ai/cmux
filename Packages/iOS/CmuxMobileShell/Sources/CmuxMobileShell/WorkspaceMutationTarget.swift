import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel

/// Routing target for a workspace mutation in the aggregated multi-Mac list.
struct WorkspaceMutationTarget {
    let client: MobileCoreRPCClient?
    let isForeground: Bool
    let macDeviceID: String?
    /// Aggregate/subscription owner key for a secondary owner. `nil` when the
    /// target is the foreground or the owner is unknown/offline.
    var ownerKey: MacPairingKey? = nil
}
