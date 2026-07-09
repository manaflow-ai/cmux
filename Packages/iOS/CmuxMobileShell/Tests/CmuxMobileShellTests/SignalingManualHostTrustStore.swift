import CmuxMobileShellModel

actor SignalingManualHostTrustStore: MobileManualHostTrustStoring {
    private var trustedScopes: Set<MobileManualHostTrustScope> = []
    private var checkCounts: [MobileManualHostTrustScope: Int] = [:]
    private var checkWaiters: [MobileManualHostTrustScope: [(
        expected: Int,
        continuation: CheckedContinuation<Void, Never>
    )]] = [:]

    func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool {
        checkCounts[scope, default: 0] += 1
        let currentCount = checkCounts[scope, default: 0]
        let waiters = checkWaiters.removeValue(forKey: scope) ?? []
        let readyWaiters = waiters.filter { $0.expected <= currentCount }
        let remainingWaiters = waiters.filter { $0.expected > currentCount }
        if !remainingWaiters.isEmpty {
            checkWaiters[scope] = remainingWaiters
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        return trustedScopes.contains(scope)
    }

    func trust(_ scope: MobileManualHostTrustScope) async {
        trustedScopes.insert(scope)
    }

    func removeAll() async {
        trustedScopes.removeAll()
    }

    func waitUntilChecked(_ scope: MobileManualHostTrustScope, count: Int) async {
        if checkCounts[scope, default: 0] >= count { return }
        await withCheckedContinuation { continuation in
            checkWaiters[scope, default: []].append((count, continuation))
        }
    }
}
