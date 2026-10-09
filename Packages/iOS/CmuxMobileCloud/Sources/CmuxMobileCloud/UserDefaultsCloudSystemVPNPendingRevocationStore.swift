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
        // Updating a scope removes its old entries and appends the current
        // set. Every entry stays until the server confirms its revocation.
        var entries = loadEntries().filter { $0.scope != scope }
        entries.append(contentsOf: revocations.sorted {
            if $0.deviceFingerprint != $1.deviceFingerprint {
                return $0.deviceFingerprint < $1.deviceFingerprint
            }
            return ($0.teamID ?? "") < ($1.teamID ?? "")
        }.map {
            (scope: scope, fingerprint: $0.deviceFingerprint, teamID: $0.teamID)
        })
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
            return stored.compactMap { entry in
                guard let scope = entry["scope"],
                      let fingerprint = entry["fingerprint"]
                else { return nil }
                return (
                    scope: scope,
                    fingerprint: fingerprint,
                    teamID: entry["teamID"]
                )
            }
        }

        // Migrate the dictionary written by earlier builds into the current
        // entry format on the next save.
        let legacy = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        var entries: [(
            scope: String,
            fingerprint: String,
            teamID: String?
        )] = []
        entries.reserveCapacity(legacy.count)
        for scope in legacy.keys.sorted() {
            for fingerprint in legacy[scope, default: []] {
                entries.append(
                    (scope: scope, fingerprint: fingerprint, teamID: nil)
                )
            }
        }
        return entries
    }
}
