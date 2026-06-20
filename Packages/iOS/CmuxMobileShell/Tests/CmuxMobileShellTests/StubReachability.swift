import CmuxMobileTransport

/// Reports a fixed online/offline verdict and never emits a path change.
struct StubReachability: ReachabilityProviding {
    let online: Bool
    var isOnline: Bool { get async { online } }
    func pathChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}
