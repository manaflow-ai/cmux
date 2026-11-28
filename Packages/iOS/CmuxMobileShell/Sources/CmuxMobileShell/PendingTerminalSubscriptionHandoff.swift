import CmuxMobileRPC
import Foundation

/// In-flight terminal subscription work captured before a peer loses focus.
struct PendingTerminalSubscriptionHandoff {
    let client: MobileCoreRPCClient
    let fenceID: UUID
    let startTask: Task<Void, Never>?
    let refreshTask: Task<Void, Never>?
    let probeTask: Task<Void, Never>?
}
