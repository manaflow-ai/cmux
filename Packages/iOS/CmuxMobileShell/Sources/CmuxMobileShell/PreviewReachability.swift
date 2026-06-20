import CmuxMobileTransport
import Foundation

struct PreviewReachability: ReachabilityProviding {
    var isOnline: Bool {
        get async { true }
    }

    func pathChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}
