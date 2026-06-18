import CmuxMobileTransport
import Foundation

struct PreviewReachability: ReachabilityProviding {
    var isOnline: Bool { true }

    func pathChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}
