public import CmuxIrohTransport
public import Foundation

/// Durable home of the device-list lease, scoped to one (account, backend)
/// pair. Release compositions back it with the Keychain
/// (`com.cmuxterm.irx.device-list.v1`); DEBUG builds use the development file
/// store in the irx state directory, mirroring every other secure store's
/// DEBUG/#else split.
///
/// Persistence keeps `issuedAt` + the wall receipt. A relaunch has no
/// monotonic continuity, so the load re-anchors the lease from the wall
/// clock and FAILS CLOSED on tampering: any wall regression (now earlier
/// than the recorded receipt) marks the snapshot stale rather than reviving
/// it, and staleness can only be repaired by a fresh server stamp.
public actor IrxDeviceListStore {
    /// Bound the server lease value before converting it into a Duration. The
    /// deployed broker currently uses one day, and this cap keeps corrupted
    /// persisted state from overflowing clock arithmetic on relaunch.
    private static let maxPersistedTTLSeconds = 365 * 24 * 60 * 60

    /// Persisted lease: the snapshot minus the process-local monotonic anchor.
    struct PersistedSnapshot: Codable, Equatable, Sendable {
        var entries: [String: IrxDeviceListEntry]
        var rev: Int
        var issuedAt: Date
        var ttlSeconds: Int
        var minimumSupportedMacVersion: String?
        var receivedAtWall: Date
    }

    private let secureStore: any CmxIrohSecureCredentialStoring
    private let account: String
    private let journal: IrxJournal
    private let wallNow: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    /// - Parameters:
    ///   - secureStore: Keychain in Release, development file store in DEBUG.
    ///   - accountID: The signed-in account whose directory this is.
    ///   - backendHost: The broker/backend host the directory came from, so
    ///     staging and production leases can never satisfy each other.
    public init(
        secureStore: any CmxIrohSecureCredentialStoring,
        accountID: String,
        backendHost: String,
        journal: IrxJournal,
        wallNow: @escaping @Sendable () -> Date = { Date() },
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.secureStore = secureStore
        account = Self.storageAccount(accountID: accountID, backendHost: backendHost)
        self.journal = journal
        self.wallNow = wallNow
        self.monotonicNow = monotonicNow
    }

    /// The contract scope is the ordered `(accountID, backendHost)` tuple. The
    /// development FILE store only accepts `[A-Za-z0-9._-]` account names, so
    /// encode each UTF-8 component as hex instead of replacing characters:
    /// lossy normalization would let two scopes share a persisted lease.
    static func storageAccount(accountID: String, backendHost: String) -> String {
        func hex(_ value: String) -> String {
            value.utf8.map { String(format: "%02x", $0) }.joined()
        }
        return "device-list-v2-\(hex(accountID))-\(hex(backendHost))"
    }

    /// Loads the persisted lease, re-anchored to the monotonic clock.
    ///
    /// A stale-but-decodable lease is RETURNED (with an already-expired
    /// monotonic anchor) instead of dropped: callers must distinguish "this
    /// device has a directory, but the lease lapsed" (fail closed) from
    /// "no directory was ever received" (bootstrap).
    public func loadPersisted() async -> IrxDeviceListSnapshot? {
        let data: Data?
        do {
            data = try await secureStore.read(account: account)
        } catch {
            journal.record(
                "device-list", "load-failed",
                ["error": String(describing: error)]
            )
            return nil
        }
        guard let data,
            let persisted = try? JSONDecoder().decode(PersistedSnapshot.self, from: data)
        else { return nil }
        guard persisted.ttlSeconds > 0,
            persisted.ttlSeconds <= Self.maxPersistedTTLSeconds
        else {
            journal.record(
                "device-list", "invalid-ttl",
                ["ttl_seconds": String(persisted.ttlSeconds)]
            )
            return nil
        }
        let now = wallNow()
        let anchor = monotonicNow()
        let elapsed = now.timeIntervalSince(persisted.receivedAtWall)
        let receivedAtMonotonic: ContinuousClock.Instant
        if elapsed < 0 {
            // Wall clock ran BACKWARD past the recorded receipt: tampering or
            // a bad clock. Fail closed by anchoring the lease as already
            // expired; only a fresh server stamp revives admission.
            journal.record(
                "device-list", "wall-clock-rollback",
                ["rev": String(persisted.rev)]
            )
            // Exactly one TTL ago is already stale (`isFresh` uses `<`), so
            // no `+ 1` is needed and this cannot overflow.
            receivedAtMonotonic = anchor.advanced(
                by: .seconds(-persisted.ttlSeconds))
        } else {
            receivedAtMonotonic = anchor.advanced(by: .seconds(-elapsed))
        }
        let snapshot = IrxDeviceListSnapshot(
            entries: persisted.entries,
            rev: persisted.rev,
            issuedAt: persisted.issuedAt,
            ttlSeconds: persisted.ttlSeconds,
            minimumSupportedMacVersion: persisted.minimumSupportedMacVersion,
            receivedAtWall: persisted.receivedAtWall,
            receivedAtMonotonic: receivedAtMonotonic
        )
        journal.record(
            "device-list", "loaded",
            [
                "rev": String(persisted.rev),
                "entries": String(persisted.entries.count),
                "fresh": String(snapshot.isFresh(now: anchor)),
            ]
        )
        return snapshot
    }

    @discardableResult
    public func persist(_ snapshot: IrxDeviceListSnapshot) async -> Bool {
        guard snapshot.ttlSeconds > 0,
            snapshot.ttlSeconds <= Self.maxPersistedTTLSeconds
        else {
            journal.record(
                "device-list", "invalid-ttl",
                ["ttl_seconds": String(snapshot.ttlSeconds)]
            )
            return false
        }
        let persisted = PersistedSnapshot(
            entries: snapshot.entries,
            rev: snapshot.rev,
            issuedAt: snapshot.issuedAt,
            ttlSeconds: snapshot.ttlSeconds,
            minimumSupportedMacVersion: snapshot.minimumSupportedMacVersion,
            receivedAtWall: snapshot.receivedAtWall
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return false }
        do {
            try await secureStore.write(
                data,
                account: account,
                accessibility: .afterFirstUnlockThisDeviceOnly
            )
            journal.record(
                "device-list", "persisted",
                ["rev": String(snapshot.rev), "entries": String(snapshot.entries.count)]
            )
            return true
        } catch {
            journal.record(
                "device-list", "persist-failed",
                ["error": String(describing: error)]
            )
            return false
        }
    }

    /// Sign-out: removes this (account, backend) lease.
    public func clear() async {
        do {
            try await secureStore.delete(account: account)
            journal.record("device-list", "cleared")
        } catch {
            journal.record(
                "device-list", "clear-failed",
                ["error": String(describing: error)]
            )
        }
    }
}
