import CmuxMobileShellModel
import Foundation

actor ImmediateExpiryManualHostTrustStore: MobileManualHostTrustStoring {
    private var expirationWasRequested = false

    func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool {
        _ = scope
        return !expirationWasRequested
    }

    func trust(_ scope: MobileManualHostTrustScope) async {
        _ = scope
    }

    func removeAll() async {
        expirationWasRequested = true
    }

    func expirationDate(for scope: MobileManualHostTrustScope) async -> Date? {
        _ = scope
        expirationWasRequested = true
        return .distantPast
    }
}
