import CmuxMobileShellModel
import Foundation

actor CountingExpirationManualHostTrustStore: MobileManualHostTrustStoring {
    private var scopes: Set<MobileManualHostTrustScope> = []
    private var expirationQueries = 0

    func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool {
        scopes.contains(scope)
    }

    func trust(_ scope: MobileManualHostTrustScope) async {
        scopes.insert(scope)
    }

    func expirationDate(for scope: MobileManualHostTrustScope) async -> Date? {
        guard scopes.contains(scope) else { return nil }
        expirationQueries += 1
        return Date().addingTimeInterval(3_600)
    }

    func removeAll() async {
        scopes.removeAll()
    }

    func expirationQueryCount() -> Int {
        expirationQueries
    }
}
