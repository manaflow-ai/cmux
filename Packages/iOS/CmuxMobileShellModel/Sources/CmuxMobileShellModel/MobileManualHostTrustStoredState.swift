import Foundation

struct MobileManualHostTrustStoredState {
    let persistedExpirations: [String: TimeInterval]
    let trustedScopes: [MobileManualHostTrustScope: TimeInterval]

    init(defaults: UserDefaults, key: String, sessionIdentifier: String) {
        let persistedExpirations: [String: TimeInterval]
        if let raw = defaults.dictionary(forKey: key) {
            persistedExpirations = raw.reduce(into: [:]) { result, entry in
                if let expiresAt = entry.value as? TimeInterval {
                    result[entry.key] = expiresAt
                } else if let expiresAt = entry.value as? NSNumber {
                    result[entry.key] = expiresAt.doubleValue
                }
            }
        } else {
            persistedExpirations = [:]
        }
        self.persistedExpirations = persistedExpirations

        let sessionPrefix = sessionIdentifier.mobileManualHostTrustStorageEscaped + "|"
        self.trustedScopes = persistedExpirations.reduce(into: [:]) { result, entry in
            guard entry.key.hasPrefix(sessionPrefix) else { return }
            let components = entry.key.dropFirst(sessionPrefix.count).split(
                separator: "|",
                omittingEmptySubsequences: false
            )
            guard components.count == 3,
                  let port = Int(components[2]),
                  let scope = MobileManualHostTrustScope(
                    host: String(components[1]).mobileManualHostTrustStorageUnescaped,
                    port: port,
                    stackUserID: String(components[0]).mobileManualHostTrustStorageUnescaped
                  ) else {
                return
            }
            result[scope] = entry.value
        }
    }
}

extension String {
    var mobileManualHostTrustStorageEscaped: String {
        self
            .replacing("%", with: "%25")
            .replacing("|", with: "%7C")
    }

    var mobileManualHostTrustStorageUnescaped: String {
        self
            .replacing("%7C", with: "|")
            .replacing("%25", with: "%")
    }
}
