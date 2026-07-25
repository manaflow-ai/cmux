import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel

/// Routing target for a workspace mutation in the aggregated multi-Mac list.
struct WorkspaceMutationTarget {
    let client: MobileCoreRPCClient?
    let isForeground: Bool
    let macDeviceID: String?
    /// Aggregate/subscription key for a secondary owner: the pairing id for a
    /// tagged Mac, the bare device id for a legacy pairing. `nil` when unknown.
    var ownerKey: String? = nil
}
