public import Foundation

/// UserDefaults-backed production store for pending browser-peer revocations.
///
/// Only account scopes and device fingerprints are stored. Access and refresh
/// tokens stay in the auth coordinator and are reacquired after the next sign-in.
    public actor UserDefaultsCloudSystemVPNPendingRevocationStore:
    CloudSystemVPNPendingRevocationStoring
{
    private let defaults: UserDefaults
    private let key: String
    private static let maxPrimaryScopes = 64
    private static let maxPrimaryFingerprintsPerScope = 64

    /// Creates a store in the supplied defaults domain.
    public init(
        defaults: UserDefaults,
        key: String = "cmux.mobile.cloudSystemVPN.pendingRevocations.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Creates a store in a named defaults suite, for isolated tests.
    public init(
        suiteName: String,
        key: String = "cmux.mobile.cloudSystemVPN.pendingRevocations.v1"
    ) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.key = key
    }

    /// Loads fingerprints pending for one account and team scope.
    public func load(scope: String) async -> Set<String> {
        let all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        var fingerprints = Set(all[scope] ?? [])
        if let overflow = defaults.array(forKey: overflowKey(scope: scope)) as? [String] {
            fingerprints.formUnion(overflow)
        }
        return fingerprints
    }

    /// Replaces pending fingerprints for one account and team scope.
    public func save(_ fingerprints: Set<String>, scope: String) async {
        // The primary dictionary is bounded so repeated account switches do
        // not make every save rewrite an ever-growing property-list value.
        // Overflow stays durable under a scope-specific key and is recovered
        // by the same load/save path, so no cleanup obligation is discarded.
        var all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        if fingerprints.isEmpty {
            all.removeValue(forKey: scope)
            defaults.removeObject(forKey: overflowKey(scope: scope))
        } else {
            let sorted = fingerprints.sorted()
            if all[scope] != nil || all.count < Self.maxPrimaryScopes {
                all[scope] = Array(sorted.prefix(Self.maxPrimaryFingerprintsPerScope))
                let overflow = Array(sorted.dropFirst(Self.maxPrimaryFingerprintsPerScope))
                if overflow.isEmpty {
                    defaults.removeObject(forKey: overflowKey(scope: scope))
                } else {
                    defaults.set(overflow, forKey: overflowKey(scope: scope))
                }
            } else {
                defaults.set(sorted, forKey: overflowKey(scope: scope))
            }
        }

        if all.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(all, forKey: key)
        }
    }

    private func overflowKey(scope: String) -> String {
        "\(key).overflow.\(Data(scope.utf8).base64EncodedString())"
    }
}
