public import Foundation

/// Account-scoped durable trust for exact SSH host-key fingerprints.
///
/// The store never treats a server-supplied fingerprint as trusted. A caller
/// must explicitly record an approved challenge, after which strict decisions
/// accept only the same profile, algorithm, and fingerprint. A changed key is
/// rejected before the SSH coordinator can load credentials.
public actor MobileRemoteHostKeyStore {
    /// Maximum retained profile observations.
    public static let maximumEntries = 1_024

    private struct File: Codable, Sendable {
        let version: Int
        let accountID: String
        var observations: [MobileRemoteHostKeyObservation]
    }

    private let databaseURL: URL
    private let accountID: String
    private let now: @Sendable () -> Date
    private var observations: [UUID: MobileRemoteHostKeyObservation]

    /// Opens an account-bound trust file without accepting its contents.
    /// - Parameters:
    ///   - databaseURL: Private application file URL.
    ///   - accountID: Authenticated cmux account namespace.
    ///   - now: Injectable clock for deterministic first/last-seen timestamps.
    /// - Throws: Invalid account or corrupt/foreign file errors.
    public init(
        databaseURL: URL,
        accountID: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard Self.validAccount(accountID) else { throw MobileRemoteHostKeyStoreError.invalidAccount }
        self.databaseURL = databaseURL
        self.accountID = accountID
        self.now = now
        if !FileManager.default.fileExists(atPath: databaseURL.path) {
            self.observations = [:]
            return
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: databaseURL))
            guard file.version == 1, file.accountID == accountID,
                  file.observations.count <= Self.maximumEntries else {
                throw MobileRemoteHostKeyStoreError.corruptStore
            }
            var values: [UUID: MobileRemoteHostKeyObservation] = [:]
            for observation in file.observations {
                guard values.updateValue(observation, forKey: observation.profileID) == nil else {
                    throw MobileRemoteHostKeyStoreError.corruptStore
                }
            }
            self.observations = values
        } catch let error as MobileRemoteHostKeyStoreError {
            throw error
        } catch {
            throw MobileRemoteHostKeyStoreError.corruptStore
        }
    }

    /// Returns the saved exact observation, if one exists.
    /// - Parameter profileID: Opaque profile identity.
    /// - Returns: The device-local trusted observation.
    public func observation(for profileID: UUID) -> MobileRemoteHostKeyObservation? {
        observations[profileID]
    }

    /// Evaluates a challenge without changing trust state.
    /// - Parameters:
    ///   - challenge: Exact key observed by the SSH engine.
    ///   - policy: User-selected ask or strict policy.
    /// - Returns: Accept only for an exact saved match; unknown ask keys remain
    ///   rejected until the user explicitly records them.
    public func decision(
        for challenge: MobileRemoteSSHHostKeyChallenge,
        policy: MobileRemoteHostKeyPolicy
    ) -> MobileRemoteSSHHostKeyDecision {
        guard let saved = observations[challenge.profileID] else { return .reject }
        return saved.algorithm == challenge.algorithm && saved.fingerprint == challenge.fingerprint
            ? .accept : .reject
    }

    /// Records an explicitly approved challenge atomically.
    /// - Parameter challenge: Exact key the user approved for this profile.
    /// - Throws: Capacity, validation, or persistence errors.
    public func record(_ challenge: MobileRemoteSSHHostKeyChallenge) throws {
        let timestamp = now()
        if let previous = observations[challenge.profileID] {
            guard previous.algorithm == challenge.algorithm,
                  previous.fingerprint == challenge.fingerprint else {
                throw MobileRemoteHostKeyStoreError.corruptStore
            }
            observations[challenge.profileID] = MobileRemoteHostKeyObservation(
                id: previous.id, profileID: previous.profileID,
                algorithm: previous.algorithm, fingerprint: previous.fingerprint,
                firstSeenAt: previous.firstSeenAt, lastSeenAt: timestamp
            )
        } else {
            guard observations.count < Self.maximumEntries else {
                throw MobileRemoteHostKeyStoreError.capacityExceeded
            }
            observations[challenge.profileID] = MobileRemoteHostKeyObservation(
                id: UUID(), profileID: challenge.profileID,
                algorithm: challenge.algorithm, fingerprint: challenge.fingerprint,
                firstSeenAt: timestamp, lastSeenAt: timestamp
            )
        }
        try persist()
    }

    /// Removes one trusted profile key after an explicit user action.
    /// - Parameter profileID: Profile whose trust should be forgotten.
    /// - Throws: Persistence errors.
    public func remove(profileID: UUID) throws {
        observations.removeValue(forKey: profileID)
        try persist()
    }

    private func persist() throws {
        let file = File(version: 1, accountID: accountID, observations: observations.values.sorted {
            $0.profileID.uuidString < $1.profileID.uuidString
        })
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: databaseURL, options: [.atomic])
        } catch {
            throw MobileRemoteHostKeyStoreError.corruptStore
        }
    }

    private static func validAccount(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
