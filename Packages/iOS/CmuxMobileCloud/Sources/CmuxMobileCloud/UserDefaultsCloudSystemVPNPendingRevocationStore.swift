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
        return Set(all[scope] ?? [])
    }

    /// Replaces pending fingerprints for one account and team scope.
    public func save(_ fingerprints: Set<String>, scope: String) async {
        // A failed revocation is an authorization cleanup obligation. Keep
        // every scope and fingerprint until its server request succeeds.
        var all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        if fingerprints.isEmpty {
            all.removeValue(forKey: scope)
        } else {
            all[scope] = Array(fingerprints.sorted())
        }

        if all.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(all, forKey: key)
        }
    }
}
