import CryptoKit
public import Foundation

/// Broker quota buckets mirrored by the native trust-broker client.
public enum CmxIrohBrokerOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case registration
    case discovery
    case pairGrant
    case endpointAttestation
    case relayCredential
    case relayPreference
    case revocation
}

/// Selects whether a trust-broker client owns its operation gate.
public enum CmxIrohBrokerBackpressureMode: Sendable {
    /// The client creates an in-memory operation gate.
    case automatic
    /// A caller-owned decorator provides the gate.
    case callerOwned
}

/// Serializes one broker operation and honors its bounded Retry-After floor.
///
/// Floors are isolated by hashed account and operation. When a state store is
/// supplied, only the hash, operation, and bounded dates are persisted.
public actor CmxIrohBrokerBackpressureGate {
    private struct Key: Codable, Hashable, Sendable {
        let accountScope: String
        let operation: CmxIrohBrokerOperation
    }

    private enum ErrorKind: Sendable {
        case brokerRateLimit(code: String?)
        case cooldown
    }

    private struct Floor: Sendable {
        let recordedAt: Date
        let retryAt: Date
        let errorKind: ErrorKind
    }

    private struct StoredFloor: Codable, Sendable {
        let key: Key
        let recordedAt: Date
        let retryAt: Date
    }

    private struct StoredRecord: Codable, Sendable {
        let version: Int
        let floors: [StoredFloor]
    }

    private struct Waiter {
        let id: UUID
        let ownerID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    static let persistenceKey = "cmux.iroh.broker-backpressure.v1"
    private static let recordVersion = 1
    private static let maximumStoredFloorCount = 64
    private static let maximumEncodedByteCount = 64 * 1_024
    private static let directClientAccountID = "cmux-direct-client"

    private let store: (any CmxIrohInstallStateStoring)?
    private let now: @Sendable () -> Date
    private var floors: [Key: Floor]
    private var owners: [Key: UUID] = [:]
    private var waiters: [Key: [Waiter]] = [:]

    /// Creates a gate. Passing `nil` keeps all state in memory.
    public init(
        store: (any CmxIrohInstallStateStoring)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
        if let store {
            floors = Self.loadPersistedFloors(store: store, now: now())
        } else {
            floors = [:]
        }
    }

    /// Throws before broker work when an operation's server floor is active.
    public func preflight(
        accountID: String,
        operation: CmxIrohBrokerOperation
    ) throws {
        try requireAvailable(key(accountID: accountID, operation: operation))
    }

    /// Runs one operation at a time for an exact account and quota bucket.
    /// Waiting callers re-check the floor after the current request finishes.
    public func perform<Result: Sendable>(
        accountID: String,
        operation: CmxIrohBrokerOperation,
        _ body: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let key = key(accountID: accountID, operation: operation)
        let ownerID = UUID()
        try await acquire(key, ownerID: ownerID)
        defer { release(key, ownerID: ownerID) }
        do {
            return try await body()
        } catch {
            recordDirective(from: error, key: key)
            throw error
        }
    }

    /// Returns the active whole-second floor for an account operation.
    public func remainingSeconds(
        accountID: String,
        operation: CmxIrohBrokerOperation
    ) -> Int? {
        remainingSeconds(for: key(accountID: accountID, operation: operation))
    }

    /// Clears persisted and in-memory floors for one account, or for all accounts.
    public func clear(accountID: String? = nil) {
        if let accountID {
            let scope = Self.accountScope(accountID)
            floors = floors.filter { $0.key.accountScope != scope }
        } else {
            floors.removeAll(keepingCapacity: false)
        }
        persistFloors()
    }

    /// Scope used by a direct client whose gate is never persisted or shared.
    static var directClientScope: String { directClientAccountID }

    private func acquire(_ key: Key, ownerID: UUID) async throws {
        try requireAvailable(key)
        if owners[key] == nil {
            owners[key] = ownerID
            return
        }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                if owners[key] == nil {
                    owners[key] = ownerID
                    continuation.resume()
                } else {
                    waiters[key, default: []].append(Waiter(
                        id: waiterID,
                        ownerID: ownerID,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(key, id: waiterID) }
        }

        do {
            try Task.checkCancellation()
            guard owners[key] == ownerID else { throw CancellationError() }
            try requireAvailable(key)
        } catch {
            cancelWaiter(key, id: waiterID)
            if owners[key] == ownerID {
                release(key, ownerID: ownerID)
            }
            throw error
        }
    }

    private func cancelWaiter(_ key: Key, id: UUID) {
        guard var pending = waiters[key],
              let index = pending.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = pending.remove(at: index)
        waiters[key] = pending.isEmpty ? nil : pending
        waiter.continuation.resume()
    }

    private func release(_ key: Key, ownerID: UUID) {
        guard owners[key] == ownerID else { return }
        owners[key] = nil
        guard var pending = waiters[key], !pending.isEmpty else {
            waiters[key] = nil
            return
        }
        let next = pending.removeFirst()
        waiters[key] = pending.isEmpty ? nil : pending
        owners[key] = next.ownerID
        next.continuation.resume()
    }

    private func requireAvailable(_ key: Key) throws {
        guard let floor = activeFloor(for: key) else { return }
        let remaining = Self.remainingSeconds(floor: floor, now: now())
        switch floor.errorKind {
        case let .brokerRateLimit(code):
            throw CmxIrohTrustBrokerClientError.rateLimited(
                code: code,
                retryAfterSeconds: remaining
            )
        case .cooldown:
            throw CmxIrohBrokerCooldownError(retryAfterSeconds: remaining)
        }
    }

    private func activeFloor(for key: Key) -> Floor? {
        guard let floor = floors[key] else { return nil }
        let current = now()
        let duration = floor.retryAt.timeIntervalSince(floor.recordedAt)
        guard floor.recordedAt <= current,
              floor.retryAt > current,
              floor.retryAt.timeIntervalSince(current)
                <= TimeInterval(CmxIrohBrokerCooldown.maximumRetryAfterSeconds),
              duration >= 1,
              duration <= TimeInterval(CmxIrohBrokerCooldown.maximumRetryAfterSeconds) else {
            floors[key] = nil
            persistFloors()
            return nil
        }
        return floor
    }

    private func remainingSeconds(for key: Key) -> Int? {
        guard let floor = activeFloor(for: key) else { return nil }
        return Self.remainingSeconds(floor: floor, now: now())
    }

    private func recordDirective(from error: any Error, key: Key) {
        let directive: (seconds: Int, kind: ErrorKind)?
        switch error as? CmxIrohTrustBrokerClientError {
        case let .rateLimited(code, retryAfterSeconds):
            directive = (
                Self.boundedRetryAfter(retryAfterSeconds),
                .brokerRateLimit(code: code)
            )
        case let .rejected(statusCode, _) where statusCode == 429:
            directive = (
                CmxIrohBrokerCooldown.defaultRateLimitedSeconds,
                .cooldown
            )
        default:
            directive = nil
        }
        guard let directive else { return }

        let recordedAt = now()
        let proposed = Floor(
            recordedAt: recordedAt,
            retryAt: recordedAt.addingTimeInterval(TimeInterval(directive.seconds)),
            errorKind: directive.kind
        )
        if let current = floors[key], current.retryAt >= proposed.retryAt { return }
        floors[key] = proposed
        persistFloors()
    }

    private func persistFloors() {
        guard let store else { return }
        let current = now()
        floors = floors.filter { $0.value.retryAt > current }
        guard !floors.isEmpty else {
            store.set(nil, forKey: Self.persistenceKey)
            return
        }
        let stored = floors.map { key, floor in
            StoredFloor(
                key: key,
                recordedAt: floor.recordedAt,
                retryAt: floor.retryAt
            )
        }.sorted {
            if $0.key.accountScope == $1.key.accountScope {
                return $0.key.operation.rawValue < $1.key.operation.rawValue
            }
            return $0.key.accountScope < $1.key.accountScope
        }
        let bounded = Array(stored.suffix(Self.maximumStoredFloorCount))
        guard let data = try? JSONEncoder().encode(StoredRecord(
            version: Self.recordVersion,
            floors: bounded
        )), data.count <= Self.maximumEncodedByteCount else {
            store.set(nil, forKey: Self.persistenceKey)
            return
        }
        store.set(data.base64EncodedString(), forKey: Self.persistenceKey)
    }

    private func key(
        accountID: String,
        operation: CmxIrohBrokerOperation
    ) -> Key {
        Key(accountScope: Self.accountScope(accountID), operation: operation)
    }

    private static func loadPersistedFloors(
        store: any CmxIrohInstallStateStoring,
        now: Date
    ) -> [Key: Floor] {
        guard let encoded = store.string(forKey: persistenceKey) else { return [:] }
        guard let data = Data(base64Encoded: encoded) else {
            store.set(nil, forKey: persistenceKey)
            return [:]
        }
        guard data.count <= maximumEncodedByteCount,
              let record = try? JSONDecoder().decode(StoredRecord.self, from: data),
              record.version == recordVersion,
              record.floors.count <= maximumStoredFloorCount else {
            store.set(nil, forKey: persistenceKey)
            return [:]
        }

        var loaded: [Key: Floor] = [:]
        var shouldRewrite = false
        for stored in record.floors {
            let duration = stored.retryAt.timeIntervalSince(stored.recordedAt)
            guard isCanonicalAccountScope(stored.key.accountScope),
                  stored.recordedAt.timeIntervalSince1970.isFinite,
                  stored.retryAt.timeIntervalSince1970.isFinite,
                  duration >= 1,
                  duration <= TimeInterval(CmxIrohBrokerCooldown.maximumRetryAfterSeconds),
                  stored.recordedAt <= now,
                  stored.retryAt.timeIntervalSince(now)
                    <= TimeInterval(CmxIrohBrokerCooldown.maximumRetryAfterSeconds),
                  stored.retryAt > now else {
                shouldRewrite = true
                continue
            }
            let floor = Floor(
                recordedAt: stored.recordedAt,
                retryAt: stored.retryAt,
                errorKind: .cooldown
            )
            if let current = loaded[stored.key], current.retryAt >= floor.retryAt {
                shouldRewrite = true
            } else {
                loaded[stored.key] = floor
            }
        }
        if shouldRewrite || loaded.isEmpty {
            if loaded.isEmpty {
                store.set(nil, forKey: persistenceKey)
            } else if let encoded = try? JSONEncoder().encode(StoredRecord(
                version: recordVersion,
                floors: loaded.map { key, floor in
                    StoredFloor(key: key, recordedAt: floor.recordedAt, retryAt: floor.retryAt)
                }
            )) {
                store.set(encoded.base64EncodedString(), forKey: persistenceKey)
            }
        }
        return loaded
    }

    private static func remainingSeconds(floor: Floor, now: Date) -> Int {
        let remaining = floor.retryAt.timeIntervalSince(now)
        let original = floor.retryAt.timeIntervalSince(floor.recordedAt)
        return min(
            CmxIrohBrokerCooldown.maximumRetryAfterSeconds,
            max(1, Int(min(remaining, original).rounded(.up)))
        )
    }

    private static func boundedRetryAfter(_ seconds: Int) -> Int {
        min(CmxIrohBrokerCooldown.maximumRetryAfterSeconds, max(1, seconds))
    }

    private static func accountScope(_ accountID: String) -> String {
        let transcript = Data("cmux/iroh/broker-backpressure/v1\0\(accountID)".utf8)
        return SHA256.hash(data: transcript)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isCanonicalAccountScope(_ value: String) -> Bool {
        value.utf8.count == SHA256.Digest.byteCount * 2
            && value.utf8.allSatisfy {
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            }
    }
}
