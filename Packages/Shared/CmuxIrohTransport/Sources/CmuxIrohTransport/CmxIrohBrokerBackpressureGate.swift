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
/// If the bounded record set overflows, one conservative global deadline keeps
/// every omitted server directive effective across relaunch.
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

    private struct StoredOverflowFloor: Codable, Sendable {
        let recordedAt: Date
        let retryAt: Date
    }

    private struct StoredRecord: Codable, Sendable {
        let version: Int
        let floors: [StoredFloor]
        let overflowFloor: StoredOverflowFloor?

        init(
            version: Int,
            floors: [StoredFloor],
            overflowFloor: StoredOverflowFloor? = nil
        ) {
            self.version = version
            self.floors = floors
            self.overflowFloor = overflowFloor
        }
    }

    private struct LoadedState {
        let floors: [Key: Floor]
        let overflowFloor: Floor?
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
    private var overflowFloor: Floor?
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
            let loaded = Self.loadPersistedState(store: store, now: now())
            floors = loaded.floors
            overflowFloor = loaded.overflowFloor
        } else {
            floors = [:]
            overflowFloor = nil
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

    /// Clears exact floors for one account, or all exact and overflow floors.
    /// A conservative overflow floor remains after an account-only clear because
    /// its omitted account scopes are intentionally not persisted.
    public func clear(accountID: String? = nil) {
        if let accountID {
            let scope = Self.accountScope(accountID)
            floors = floors.filter { $0.key.accountScope != scope }
        } else {
            floors.removeAll(keepingCapacity: false)
            overflowFloor = nil
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
        let current = now()
        var changed = false
        let keyedFloor: Floor?
        if let floor = floors[key], Self.isActive(floor, at: current) {
            keyedFloor = floor
        } else {
            changed = floors[key] != nil
            floors[key] = nil
            keyedFloor = nil
        }

        let activeOverflowFloor: Floor?
        if let floor = overflowFloor, Self.isActive(floor, at: current) {
            activeOverflowFloor = floor
        } else {
            changed = changed || overflowFloor != nil
            overflowFloor = nil
            activeOverflowFloor = nil
        }
        if changed { persistFloors() }

        switch (keyedFloor, activeOverflowFloor) {
        case let (keyed?, overflow?):
            return keyed.retryAt >= overflow.retryAt ? keyed : overflow
        case let (keyed?, nil):
            return keyed
        case let (nil, overflow?):
            return overflow
        case (nil, nil):
            return nil
        }
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
        floors = floors.filter { Self.isActive($0.value, at: current) }
        if let floor = overflowFloor, !Self.isActive(floor, at: current) {
            overflowFloor = nil
        }
        guard !floors.isEmpty || overflowFloor != nil else {
            store.set(nil, forKey: Self.persistenceKey)
            return
        }
        let ordered = floors.map { key, floor in
            StoredFloor(
                key: key,
                recordedAt: floor.recordedAt,
                retryAt: floor.retryAt
            )
        }.sorted(by: Self.precedesForPersistence)
        let bounded = Array(ordered.prefix(Self.maximumStoredFloorCount))
        let omitted = ordered.dropFirst(Self.maximumStoredFloorCount)
        // Retain the longest exact floors. The longest omitted deadline becomes
        // a global fallback because the omitted account-operation keys are not
        // otherwise recoverable after relaunch.
        let omittedOverflow = omitted.map {
            Floor(
                recordedAt: $0.recordedAt,
                retryAt: $0.retryAt,
                errorKind: .cooldown
            )
        }.max(by: { $0.retryAt < $1.retryAt })
        if let omittedOverflow {
            if let currentOverflow = overflowFloor {
                if currentOverflow.retryAt < omittedOverflow.retryAt {
                    overflowFloor = omittedOverflow
                }
            } else {
                overflowFloor = omittedOverflow
            }
        }
        let storedOverflow = overflowFloor.map {
            StoredOverflowFloor(recordedAt: $0.recordedAt, retryAt: $0.retryAt)
        }
        guard let data = try? JSONEncoder().encode(StoredRecord(
            version: Self.recordVersion,
            floors: bounded,
            overflowFloor: storedOverflow
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

    private static func loadPersistedState(
        store: any CmxIrohInstallStateStoring,
        now: Date
    ) -> LoadedState {
        let empty = LoadedState(floors: [:], overflowFloor: nil)
        guard let encoded = store.string(forKey: persistenceKey) else { return empty }
        guard let data = Data(base64Encoded: encoded) else {
            store.set(nil, forKey: persistenceKey)
            return empty
        }
        guard data.count <= maximumEncodedByteCount,
              let record = try? JSONDecoder().decode(StoredRecord.self, from: data),
              record.version == recordVersion,
              record.floors.count <= maximumStoredFloorCount else {
            store.set(nil, forKey: persistenceKey)
            return empty
        }

        var loaded: [Key: Floor] = [:]
        var shouldRewrite = false
        for stored in record.floors {
            guard isCanonicalAccountScope(stored.key.accountScope),
                  let floor = restoredFloor(
                      recordedAt: stored.recordedAt,
                      retryAt: stored.retryAt,
                      now: now
                  ) else {
                shouldRewrite = true
                continue
            }
            if let current = loaded[stored.key], current.retryAt >= floor.retryAt {
                shouldRewrite = true
            } else {
                loaded[stored.key] = floor
            }
        }

        let loadedOverflow: Floor?
        if let stored = record.overflowFloor {
            loadedOverflow = restoredFloor(
                recordedAt: stored.recordedAt,
                retryAt: stored.retryAt,
                now: now
            )
            if loadedOverflow == nil { shouldRewrite = true }
        } else {
            loadedOverflow = nil
        }

        if shouldRewrite || (loaded.isEmpty && loadedOverflow == nil) {
            if loaded.isEmpty && loadedOverflow == nil {
                store.set(nil, forKey: persistenceKey)
            } else if let encoded = try? JSONEncoder().encode(StoredRecord(
                version: recordVersion,
                floors: loaded.map { key, floor in
                    StoredFloor(key: key, recordedAt: floor.recordedAt, retryAt: floor.retryAt)
                },
                overflowFloor: loadedOverflow.map {
                    StoredOverflowFloor(recordedAt: $0.recordedAt, retryAt: $0.retryAt)
                }
            )) {
                store.set(encoded.base64EncodedString(), forKey: persistenceKey)
            }
        }
        return LoadedState(floors: loaded, overflowFloor: loadedOverflow)
    }

    private static func restoredFloor(
        recordedAt: Date,
        retryAt: Date,
        now: Date
    ) -> Floor? {
        let floor = Floor(
            recordedAt: recordedAt,
            retryAt: retryAt,
            errorKind: .cooldown
        )
        return isActive(floor, at: now) ? floor : nil
    }

    private static func isActive(_ floor: Floor, at current: Date) -> Bool {
        let duration = floor.retryAt.timeIntervalSince(floor.recordedAt)
        return floor.recordedAt.timeIntervalSince1970.isFinite
            && floor.retryAt.timeIntervalSince1970.isFinite
            && floor.recordedAt <= current
            && floor.retryAt > current
            && floor.retryAt.timeIntervalSince(current)
                <= TimeInterval(CmxIrohBrokerCooldown.maximumRetryAfterSeconds)
            && duration >= 1
            && duration <= TimeInterval(CmxIrohBrokerCooldown.maximumRetryAfterSeconds)
    }

    private static func precedesForPersistence(
        _ lhs: StoredFloor,
        _ rhs: StoredFloor
    ) -> Bool {
        if lhs.retryAt != rhs.retryAt { return lhs.retryAt > rhs.retryAt }
        if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
        if lhs.key.accountScope != rhs.key.accountScope {
            return lhs.key.accountScope < rhs.key.accountScope
        }
        return lhs.key.operation.rawValue < rhs.key.operation.rawValue
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
