import Foundation

/// Secure account-scoped cache for requested and effective relay preferences.
public actor CmxIrohRelayPreferenceStore {
    private struct Record: Codable {
        let version: Int
        let preference: CmxIrohPersistedRelayPreference
    }

    private static let recordVersion = 4
    private let secureStore: any CmxIrohSecureCredentialStoring
    private var busyAccounts: Set<String> = []
    private var accountWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Creates an isolated preference cache.
    public init(
        secureStore: any CmxIrohSecureCredentialStoring = CmxIrohKeychainCredentialStore(
            service: "com.cmuxterm.iroh.relay-preference.v1"
        )
    ) {
        self.secureStore = secureStore
    }

    /// Installs one preference revision with rollback and equivocation protection.
    /// A newer signed policy publication may rebase equivalent active authority
    /// after the broker restores its database without lowering stale-response protection.
    @discardableResult
    public func install(
        requested: CmxIrohAccountRelayConfiguration,
        effective: CmxIrohAccountRelayPreference?,
        revision: Int64,
        effectivePolicySequence: Int64?,
        policy: CmxIrohManagedRelayPolicy?,
        legacyPolicy: CmxIrohManagedRelayPolicy? = nil,
        legacyPolicySequence: Int64? = nil,
        staleRelayIDs: Set<String>,
        accountID: String
    ) async throws -> CmxIrohPersistedRelayPreference {
        guard revision >= 0,
              effectivePolicySequence.map({ $0 > 0 }) ?? true,
              staleRelayIDs.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        _ = try JSONEncoder().encode(requested)
        if let effective { _ = try JSONEncoder().encode(effective) }
        let account = try CmxIrohRelayStorageScope.account(
            accountID,
            prefix: "relay-preference"
        )
        await acquire(account)
        defer { release(account) }
        let existing = try await storedRecord(account: account)?.preference
        if let existing {
            try CmxIrohRelayPreferenceRevisionValidation.validate(
                incomingRevision: revision,
                incomingConfiguration: requested,
                incomingPublication: policy.map(CmxIrohRelayPolicyPublication.init),
                currentRevision: existing.revision,
                currentConfiguration: existing.requested,
                currentPublication: CmxIrohRelayPolicyPublication(
                    policyID: existing.policyID,
                    sequence: existing.policySequence,
                    issuedAt: existing.policyIssuedAt
                ) ?? legacyPolicy.map(CmxIrohRelayPolicyPublication.init),
                currentPolicySequence: existing.policySequence
                    ?? existing.effectivePolicySequence
                    ?? legacyPolicySequence
                    ?? legacyPolicy?.sequence
            )
        }
        let publication = policy.map(CmxIrohRelayPolicyPublication.init)
            ?? CmxIrohRelayPolicyPublication(
                policyID: existing?.policyID,
                sequence: existing?.policySequence,
                issuedAt: existing?.policyIssuedAt
            )
        let preference = CmxIrohPersistedRelayPreference(
            requested: requested,
            effective: effective,
            revision: revision,
            effectivePolicySequence: effectivePolicySequence,
            policyID: publication?.policyID,
            policySequence: publication?.sequence
                ?? existing?.policySequence
                ?? legacyPolicySequence,
            policyIssuedAt: publication?.issuedAt,
            staleRelayIDs: staleRelayIDs
        )
        try await secureStore.write(
            JSONEncoder().encode(Record(version: Self.recordVersion, preference: preference)),
            account: account,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        return preference
    }

    /// Loads the last validated preference for one authenticated account.
    public func load(accountID: String) async throws -> CmxIrohPersistedRelayPreference? {
        let account = try CmxIrohRelayStorageScope.account(
            accountID,
            prefix: "relay-preference"
        )
        await acquire(account)
        defer { release(account) }
        return try await storedRecord(account: account)?.preference
    }

    /// Removes the cached preference for one authenticated account.
    public func deactivate(accountID: String) async throws {
        let account = try CmxIrohRelayStorageScope.account(
            accountID,
            prefix: "relay-preference"
        )
        await acquire(account)
        defer { release(account) }
        try await secureStore.delete(account: account)
    }

    private func acquire(_ account: String) async {
        guard busyAccounts.contains(account) else {
            busyAccounts.insert(account)
            return
        }
        await withCheckedContinuation { continuation in
            accountWaiters[account, default: []].append(continuation)
        }
    }

    private func release(_ account: String) {
        guard var waiters = accountWaiters[account], !waiters.isEmpty else {
            busyAccounts.remove(account)
            accountWaiters.removeValue(forKey: account)
            return
        }
        let next = waiters.removeFirst()
        if waiters.isEmpty {
            accountWaiters.removeValue(forKey: account)
        } else {
            accountWaiters[account] = waiters
        }
        next.resume()
    }

    private func storedRecord(account: String) async throws -> Record? {
        guard let data = try await secureStore.read(account: account) else { return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              (1 ... Self.recordVersion).contains(record.version),
              record.preference.revision >= 0,
              record.preference.effectivePolicySequence.map({ $0 > 0 }) ?? true,
              record.preference.policySequence.map({ $0 > 0 }) ?? true,
              Self.hasValidPublicationShape(record.preference),
              record.preference.staleRelayIDs.count
                <= CmxIrohRelayPolicyVerifier.maximumRelayCount,
              (try? JSONEncoder().encode(record.preference.requested)) != nil,
              record.preference.effective.map({
                  (try? JSONEncoder().encode($0)) != nil
              }) ?? true else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        return record
    }

    private static func hasValidPublicationShape(
        _ preference: CmxIrohPersistedRelayPreference
    ) -> Bool {
        if preference.policyID == nil,
           preference.policyIssuedAt == nil,
           preference.policySequence == nil {
            return true
        }
        guard let policyID = preference.policyID,
              let issuedAt = preference.policyIssuedAt,
              issuedAt >= 0,
              UUID(uuidString: policyID)?.uuidString.lowercased() == policyID else {
            return false
        }
        // Version 3 records carried authenticated identity and issue time but
        // predate the explicit publication sequence.
        return preference.policySequence.map({ $0 > 0 }) ?? true
    }
}
