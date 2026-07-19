import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// Routing target for a workspace mutation in the aggregated multi-Mac list.
struct WorkspaceMutationTarget {
    let client: MobileCoreRPCClient?
    let route: CmxAttachRoute?
    let connectionGeneration: UUID?
    let isForeground: Bool
    let macDeviceID: String?
}
