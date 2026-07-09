import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel

/// Routing target for a workspace mutation in the aggregated multi-Mac list.
struct WorkspaceMutationTarget {
    let client: MobileCoreRPCClient?
    let route: CmxAttachRoute?
    let isForeground: Bool
    let macDeviceID: String?
}
