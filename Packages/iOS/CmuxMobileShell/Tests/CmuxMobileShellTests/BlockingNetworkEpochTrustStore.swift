import CmuxMobileShellModel

actor BlockingNetworkEpochTrustStore: MobileManualHostTrustStoring {
    private var removeCount = 0
    private var trustCount = 0
    private var removeWaiters: [(
        expected: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool {
        _ = scope
        return false
    }

    func trust(_ scope: MobileManualHostTrustScope) async {
        _ = scope
        trustCount += 1
    }

    func removeAll() async {
        removeCount += 1
        let readyWaiters = removeWaiters.filter { $0.expected <= removeCount }
        removeWaiters.removeAll { $0.expected <= removeCount }
        for waiter in readyWaiters { waiter.continuation.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilRemoveCount(_ expected: Int) async {
        if removeCount >= expected { return }
        await withCheckedContinuation { removeWaiters.append((expected, $0)) }
    }

    func currentRemoveCount() -> Int {
        removeCount
    }

    func currentTrustCount() -> Int {
        trustCount
    }

    func releaseRemovals() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
