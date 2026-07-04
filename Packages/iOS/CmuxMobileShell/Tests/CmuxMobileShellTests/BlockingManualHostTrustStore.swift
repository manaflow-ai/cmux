import CmuxMobileShellModel

actor BlockingManualHostTrustStore: MobileManualHostTrustStoring {
    private var didBlockFirstLookup = false
    private var didEnterFirstLookup = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilFirstLookupIsBlocked() async {
        if didEnterFirstLookup {
            return
        }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func releaseFirstLookup() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool {
        _ = scope
        if !didBlockFirstLookup {
            didBlockFirstLookup = true
            didEnterFirstLookup = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return false
    }

    func trust(_ scope: MobileManualHostTrustScope) async {
        _ = scope
    }

    func removeAll() async {}
}
