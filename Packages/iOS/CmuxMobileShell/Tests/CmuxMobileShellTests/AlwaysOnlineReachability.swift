import CmuxMobileTransport

struct AlwaysOnlineReachability: ReachabilityProviding {
    var isOnline: Bool { get async { true } }

    func pathChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
