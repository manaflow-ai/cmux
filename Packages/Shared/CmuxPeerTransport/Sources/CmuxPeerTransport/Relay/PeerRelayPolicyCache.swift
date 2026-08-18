public import Foundation

/// Device-local persistence boundary for the signed relay-policy record.
///
/// The engine provides a Keychain-backed conformance; tests use an in-memory
/// one. The stored bytes are an opaque JSON record owned by
/// ``PeerRelayPolicyCache``, byte-compatible with the legacy cache record so
/// a store pointed at the legacy Keychain item keeps its rollback floor.
public protocol PeerRelayPolicyStoring: Sendable {
    /// Returns the stored record bytes, or `nil` when nothing is stored.
    func readRecord() async throws -> Data?

    /// Atomically replaces the stored record bytes.
    func writeRecord(_ data: Data) async throws

    /// Removes every stored relay-policy record.
    func removeAll() async throws
}

/// Securely caches the latest root-verified relay policy with rollback
/// protection.
///
/// A cached policy is usable only until its signed expiry: `load` re-verifies
/// the stored JWS at the current time, and ``resolve(trustRoot:now:)`` maps
/// every rejection class (invalid, expired, rolled back, missing, storage
/// failure) to direct-only connectivity with zero relays.
public actor PeerRelayPolicyCache {
    private struct CachedRelay: Codable, Equatable {
        let id: String
        let provider: String
        let region: String
        let url: String

        init(_ relay: PeerRelayDescriptor) {
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

    private static let recordVersion = 1

    private let store: any PeerRelayPolicyStoring
    private let verifier: PeerRelayPolicyVerifier
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates an isolated relay-policy cache.
    ///
    /// - Parameters:
    ///   - store: Device-local secure persistence for the signed policy record.
    ///   - verifier: The stateless root-pinned policy verifier.
    public init(
        store: any PeerRelayPolicyStoring,
        verifier: PeerRelayPolicyVerifier = PeerRelayPolicyVerifier()
    ) {
        self.store = store
        self.verifier = verifier
    }

    /// Verifies and installs a policy unless it rolls back the stored sequence.
    ///
    /// - Parameters:
    ///   - signedPolicy: Compact JWS policy returned by the broker.
    ///   - trustRoot: App-pinned public verification keys.
    ///   - now: Verification time.
    /// - Returns: The verified installed policy.
    /// - Throws: ``PeerRelayPolicyError`` or a secure-storage error.
    public func install(
        signedPolicy: String,
        trustRoot: PeerRelayPolicyTrustRoot,
        now: Date
    ) async throws -> PeerRelayPolicy {
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
                throw PeerRelayPolicyError.rollback
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
        try await store.writeRecord(JSONEncoder().encode(record))
        return policy
    }

    /// Loads and re-verifies the cached policy at the current time.
    ///
    /// - Parameters:
    ///   - trustRoot: App-pinned public verification keys.
    ///   - now: Verification time.
    /// - Returns: The verified policy, or `nil` when no policy is cached.
    /// - Throws: ``PeerRelayPolicyError`` or a secure-storage error.
    public func load(
        trustRoot: PeerRelayPolicyTrustRoot,
        now: Date
    ) async throws -> PeerRelayPolicy? {
        await acquire()
        defer { release() }
        guard let record = try await storedRecord() else { return nil }
        let policy = try verifier.verify(record.signedPolicy, trustRoot: trustRoot, now: now)
        guard policy.sequence == record.highestSequence,
              Self.metadataMatches(policy, record: record) else {
            throw PeerRelayPolicyError.rollback
        }
        return policy
    }

    /// Resolves the cached policy, failing closed to direct-only connectivity.
    ///
    /// Never throws: an invalid, expired, rolled-back, unreadable, or missing
    /// record yields ``PeerRelayPolicyResolution/directOnly(_:)`` so the
    /// endpoint is configured with zero relays rather than unverified ones.
    public func resolve(
        trustRoot: PeerRelayPolicyTrustRoot,
        now: Date
    ) async -> PeerRelayPolicyResolution {
        do {
            guard let policy = try await load(trustRoot: trustRoot, now: now) else {
                return .directOnly(.missing)
            }
            return .verified(policy)
        } catch let error as PeerRelayPolicyError {
            switch error {
            case .expired:
                return .directOnly(.expired)
            case .rollback:
                return .directOnly(.rollback)
            default:
                return .directOnly(.invalid)
            }
        } catch {
            // Storage failures also fail closed.
            return .directOnly(.invalid)
        }
    }

    /// Removes every cached relay-policy record.
    public func deactivate() async throws {
        await acquire()
        defer { release() }
        try await store.removeAll()
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
        guard let data = try await store.readRecord() else {
            return nil
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == Self.recordVersion,
              record.highestSequence > 0,
              Self.hasValidMetadataShape(record) else {
            // Deleting an unreadable record would also delete the monotonic
            // rollback floor. Keep it quarantined until explicit deactivation
            // so an older, still-valid signed policy cannot replace it.
            throw PeerRelayPolicyError.invalidClaims
        }
        return record
    }

    private static func isSafeRenewal(
        _ policy: PeerRelayPolicy,
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
        _ policy: PeerRelayPolicy,
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
            && catalog.count <= PeerRelayPolicyVerifier.maximumRelayCount
            && issuedAt >= 0
            && expiresAt > issuedAt
    }
}
