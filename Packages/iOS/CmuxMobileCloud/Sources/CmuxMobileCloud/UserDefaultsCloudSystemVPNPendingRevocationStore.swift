public import Foundation

/// UserDefaults-backed production store for pending browser-peer revocations.
///
/// Only account scopes and device fingerprints are stored. Access and refresh
/// tokens stay in the auth coordinator and are reacquired after the next sign-in.
public actor UserDefaultsCloudSystemVPNPendingRevocationStore:
    CloudSystemVPNPendingRevocationStoring
{
    private static let maxScopes = 64
    private static let maxFingerprintsPerScope = 8
    private let defaults: UserDefaults
    private let key: String
    private let updatedAtKey: String

    /// Creates a store in the supplied defaults domain.
    public init(
        defaults: UserDefaults,
        key: String = "cmux.mobile.cloudSystemVPN.pendingRevocations.v1"
    ) {
        self.defaults = defaults
        self.key = key
        self.updatedAtKey = "\(key).updatedAt"
    }

    /// Creates a store in a named defaults suite, for isolated tests.
    public init(
        suiteName: String,
        key: String = "cmux.mobile.cloudSystemVPN.pendingRevocations.v1"
    ) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.key = key
        self.updatedAtKey = "\(key).updatedAt"
    }

    /// Loads fingerprints pending for one account and team scope.
    public func load(scope: String) async -> Set<String> {
        let all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return Set(all[scope] ?? [])
    }

    /// Replaces pending fingerprints for one account and team scope.
    public func save(_ fingerprints: Set<String>, scope: String) async {
        var all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        var updatedAt = defaults.dictionary(forKey: updatedAtKey).map {
            $0.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        } ?? [:]
        if fingerprints.isEmpty {
            all.removeValue(forKey: scope)
            updatedAt.removeValue(forKey: scope)
        } else {
            all[scope] = Array(fingerprints.sorted().prefix(Self.maxFingerprintsPerScope))
            updatedAt[scope] = Date().timeIntervalSince1970
        }

        if all.count > Self.maxScopes {
            let otherScopes = all.keys.filter { $0 != scope }.sorted {
                let lhs = updatedAt[$0] ?? 0
                let rhs = updatedAt[$1] ?? 0
                return lhs == rhs ? $0 > $1 : lhs > rhs
            }
            var retainedScopes = Set(otherScopes.prefix(Self.maxScopes - 1))
            if all[scope] != nil {
                retainedScopes.insert(scope)
            }
            all = all.filter { retainedScopes.contains($0.key) }
            updatedAt = updatedAt.filter { retainedScopes.contains($0.key) }
        }

        if all.isEmpty {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: updatedAtKey)
        } else {
            defaults.set(all, forKey: key)
            defaults.set(updatedAt, forKey: updatedAtKey)
        }
    }
}
