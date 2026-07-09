import CmuxMobileShellModel
import CmuxMobileTransport

struct ControllablePathChangeReachability: ReachabilityProviding, Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    var isOnline: Bool { get async { true } }

    func pathChanges() -> AsyncStream<Void> { stream }

    func emitPathChange() { continuation.yield(()) }
}

actor NetworkEpochManualHostTrustStore: MobileManualHostTrustStoring {
    private var scopes: Set<MobileManualHostTrustScope> = []
    private var didRemoveAll = false
    private var removeWaiters: [CheckedContinuation<Void, Never>] = []

    func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool {
        scopes.contains(scope)
    }

    func trust(_ scope: MobileManualHostTrustScope) async {
        scopes.insert(scope)
    }

    func removeAll() async {
        scopes.removeAll()
        didRemoveAll = true
        let waiters = removeWaiters
        removeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilRemoved() async {
        if didRemoveAll { return }
        await withCheckedContinuation { removeWaiters.append($0) }
    }
}
