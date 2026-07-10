import CmuxMobileShellModel

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
