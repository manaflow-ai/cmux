import CmuxMobileShellModel

actor BlockingManualHostTrustPersistenceStore: MobileManualHostTrustStoring {
    private var trustedScopes: Set<MobileManualHostTrustScope> = []
    private var didEnterTrust = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilTrustIsBlocked() async {
        if didEnterTrust {
            return
        }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func releaseTrust() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool {
        trustedScopes.contains(scope)
    }

    func trust(_ scope: MobileManualHostTrustScope) async {
        didEnterTrust = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        guard !Task.isCancelled else { return }
        trustedScopes.insert(scope)
    }

    func removeAll() async {
        trustedScopes.removeAll()
    }
}
