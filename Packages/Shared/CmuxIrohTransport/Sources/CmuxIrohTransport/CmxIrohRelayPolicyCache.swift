public import Foundation

/// Securely caches the latest root-verified relay policy with rollback protection.
public actor CmxIrohRelayPolicyCache {
    private struct CachedRelay: Codable, Equatable {
        let id: String
        let provider: String
        let region: String
        let url: String

        init(_ relay: CmxIrohManagedRelayDescriptor) {
            id = relay.id
            provider = relay.provider
            region = relay.region
            url = relay.url
        }
    }

    private struct Record: Codable {
        let version: Int
        let highestSequence: Int64
        let signedPolicy: String
        // Optional for records written before renewable same-catalog policies.
        let catalog: [CachedRelay]?
        let issuedAt: Int64?
        let expiresAt: Int64?
    }

    private static let storageAccount = "managed-relay-policy"
    private static let recordVersion = 1

    private let secureStore: any CmxIrohSecureCredentialStoring
    private let verifier: CmxIrohRelayPolicyVerifier
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates an isolated relay-policy cache.
    ///
    /// - Parameters:
    ///   - secureStore: Device-local secure persistence for the signed policy record.
    ///   - verifier: The stateless root-pinned policy verifier.
    public init(
        secureStore: any CmxIrohSecureCredentialStoring = CmxIrohKeychainCredentialStore(
            service: "com.cmuxterm.iroh.relay-policy.v1"
        ),
        verifier: CmxIrohRelayPolicyVerifier = CmxIrohRelayPolicyVerifier()
    ) {
        self.secureStore = secureStore
        self.verifier = verifier
    }

    /// Verifies and installs a policy unless it rolls back the stored sequence.
    ///
    /// - Parameters:
    ///   - signedPolicy: Compact JWS policy returned by the broker.
    ///   - trustRoot: App-pinned public verification keys.
    ///   - now: Verification time.
    /// - Returns: The verified installed policy.
    /// - Throws: ``CmxIrohRelayPolicyError`` or a secure-storage error.
    public func install(
        signedPolicy: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date
    ) async throws -> CmxIrohManagedRelayPolicy {
        await acquire()
        defer { release() }
        let policy = try verifier.verify(signedPolicy, trustRoot: trustRoot, now: now)
        let existing = try await storedRecord()
        if let existing {
            guard policy.sequence > existing.highestSequence
                    || Self.isSafeRenewal(
                        policy,
                        signedPolicy: signedPolicy,
                        of: existing
                    ) else {
                throw CmxIrohRelayPolicyError.rollback
            }
        }
        let record = Record(
            version: Self.recordVersion,
            highestSequence: max(policy.sequence, existing?.highestSequence ?? 0),
            signedPolicy: signedPolicy,
            catalog: policy.relays.map(CachedRelay.init),
            issuedAt: policy.issuedAt,
            expiresAt: policy.expiresAt
        )
        try await secureStore.write(
            JSONEncoder().encode(record),
            account: Self.storageAccount,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        return policy
    }

    /// Loads and re-verifies the cached policy at the current time.
    ///
    /// - Parameters:
    ///   - trustRoot: App-pinned public verification keys.
    ///   - now: Verification time.
    /// - Returns: The verified policy, or `nil` when no policy is cached.
    /// - Throws: ``CmxIrohRelayPolicyError`` or a secure-storage error.
    public func load(
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date
    ) async throws -> CmxIrohManagedRelayPolicy? {
        await acquire()
        defer { release() }
        guard let record = try await storedRecord() else { return nil }
        let policy = try verifier.verify(record.signedPolicy, trustRoot: trustRoot, now: now)
        guard policy.sequence == record.highestSequence,
              Self.metadataMatches(policy, record: record) else {
            throw CmxIrohRelayPolicyError.rollback
        }
        return policy
    }

    /// Removes every cached relay-policy record.
    public func deactivate() async throws {
        await acquire()
        defer { release() }
        try await secureStore.deleteAll()
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            busy = false
            return
        }
        waiters.removeFirst().resume()
    }

    private func storedRecord() async throws -> Record? {
        guard let data = try await secureStore.read(account: Self.storageAccount) else {
            return nil
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == Self.recordVersion,
              record.highestSequence > 0,
              Self.hasValidMetadataShape(record) else {
            // Deleting an unreadable record would also delete the monotonic
            // rollback floor. Keep it quarantined until explicit deactivation
            // so an older, still-valid signed policy cannot replace it.
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        return record
    }

    private static func isSafeRenewal(
        _ policy: CmxIrohManagedRelayPolicy,
        signedPolicy: String,
        of existing: Record
    ) -> Bool {
        guard policy.sequence == existing.highestSequence else { return false }
        guard let catalog = existing.catalog,
              let issuedAt = existing.issuedAt,
              let expiresAt = existing.expiresAt else {
            // Preserve the previous exact-token behavior for legacy records.
            return signedPolicy == existing.signedPolicy
        }
        return policy.relays.map(CachedRelay.init) == catalog
            && policy.issuedAt >= issuedAt
            && policy.expiresAt >= expiresAt
    }

    private static func metadataMatches(
        _ policy: CmxIrohManagedRelayPolicy,
        record: Record
    ) -> Bool {
        guard let catalog = record.catalog,
              let issuedAt = record.issuedAt,
              let expiresAt = record.expiresAt else {
            return true
        }
        return policy.relays.map(CachedRelay.init) == catalog
            && policy.issuedAt == issuedAt
            && policy.expiresAt == expiresAt
    }

    private static func hasValidMetadataShape(_ record: Record) -> Bool {
        let valuesPresent = [
            record.catalog != nil,
            record.issuedAt != nil,
            record.expiresAt != nil,
        ]
        guard valuesPresent.allSatisfy({ $0 }) || valuesPresent.allSatisfy({ !$0 }) else {
            return false
        }
        guard let catalog = record.catalog,
              let issuedAt = record.issuedAt,
              let expiresAt = record.expiresAt else { return true }
        return !catalog.isEmpty
            && catalog.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount
            && issuedAt >= 0
            && expiresAt > issuedAt
    }
}
