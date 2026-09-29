public import Foundation

/// UserDefaults-backed production store for pending browser-peer revocations.
///
/// Account scopes, device fingerprints, and owning team IDs are stored. Access
/// and refresh tokens stay in the auth coordinator and are reacquired after
/// the next sign-in.
    public actor UserDefaultsCloudSystemVPNPendingRevocationStore:
    CloudSystemVPNPendingRevocationStoring
{
    private let defaults: UserDefaults
    private let key: String
    private static let maxPersistedEntries = 4096

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

    /// Loads pending browser-peer revocations for one account and team scope.
    public func load(scope: String) async -> Set<CloudSystemVPNPendingRevocation> {
        Set(loadEntries().compactMap { entry in
            guard entry.scope == scope else { return nil }
            return CloudSystemVPNPendingRevocation(
                deviceFingerprint: entry.fingerprint,
                teamID: entry.teamID
            )
        })
    }

    /// Replaces pending browser-peer revocations for one account and team scope.
    public func save(
        _ revocations: Set<CloudSystemVPNPendingRevocation>,
        scope: String
    ) async {
        // This is an explicit FIFO retention policy. Updating a scope removes
        // its old entries and appends the current set, so new cleanup work is
        // retained. When the fixed capacity is full, the oldest entries are
        // evicted instead of growing UserDefaults without a bound.
        var entries = loadEntries().filter { $0.scope != scope }
        entries.append(contentsOf: revocations.sorted {
            if $0.deviceFingerprint != $1.deviceFingerprint {
                return $0.deviceFingerprint < $1.deviceFingerprint
            }
            return ($0.teamID ?? "") < ($1.teamID ?? "")
        }.map {
            (scope: scope, fingerprint: $0.deviceFingerprint, teamID: $0.teamID)
        })
        if entries.count > Self.maxPersistedEntries {
            entries.removeFirst(entries.count - Self.maxPersistedEntries)
        }

        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(
                entries.map { entry in
                    var value = [
                        "scope": entry.scope,
                        "fingerprint": entry.fingerprint
                    ]
                    if let teamID = entry.teamID {
                        value["teamID"] = teamID
                    }
                    return value
                },
                forKey: key
            )
        }
    }

    private func loadEntries() -> [(
        scope: String,
        fingerprint: String,
        teamID: String?
    )] {
        if let stored = defaults.array(forKey: key) as? [[String: String]] {
            return Array(stored.compactMap { entry in
                guard let scope = entry["scope"],
                      let fingerprint = entry["fingerprint"]
                else { return nil }
                return (
                    scope: scope,
                    fingerprint: fingerprint,
                    teamID: entry["teamID"]
                )
            }.prefix(Self.maxPersistedEntries))
        }

        // Migrate the dictionary written by earlier builds into the bounded
        // FIFO format on the next save.
        let legacy = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        let entries = legacy.keys.sorted().flatMap { scope in
            legacy[scope, default: []].sorted().map {
                (scope: scope, fingerprint: $0, teamID: Optional<String>.none)
            }
        }
        return Array(entries.prefix(Self.maxPersistedEntries))
    }
}
