import Foundation

/// Persists one stable WebKit data-store identifier per browser auth scope.
struct BrowserWebsiteDataStoreIDStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func identifier(for scope: BrowserPersistenceScope) -> UUID {
        var identifiers = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let scopeKey = encodedScopeKey(scope)
        if let rawIdentifier = identifiers[scopeKey], let identifier = UUID(uuidString: rawIdentifier) {
            return identifier
        }
        let identifier = UUID()
        identifiers[scopeKey] = identifier.uuidString
        defaults.set(identifiers, forKey: key)
        return identifier
    }

    private func encodedScopeKey(_ scope: BrowserPersistenceScope) -> String {
        let user = Data(scope.userID.utf8).base64EncodedString()
        let team = scope.teamID.map { Data($0.utf8).base64EncodedString() } ?? "-"
        return "\(user).\(team)"
    }
}
