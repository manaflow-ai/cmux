public import CmuxMobilePairedMac
public import Foundation

/// Transparent local→DO migration (DESIGN.md §6). On sign-in, the phone's
/// existing `MobilePairedMacStore` paired Macs are seeded into the local
/// `CmuxSyncStore` `devices` collection as PROVISIONAL records (`rev == 0`), so
/// the new local-first list renders instantly on the very first launch after
/// upgrade — using data the phone already had, before any DO snapshot arrives.
///
/// The phone never writes the DO (it does not own a Mac's record; the Mac does,
/// via its presence heartbeat). It only seeds the local cache. When the DO
/// snapshot/delta arrives, its authoritative records (`rev >= 1`) overwrite the
/// provisional rows by the normal apply guard. Provisional rows for Macs the DO
/// does not know about survive as a best-effort fallback (the §3.2a snapshot
/// reconciliation is scoped to `rev >= 1` and never deletes `rev == 0` rows).
///
/// Idempotent two ways: a `migrated:<accountId>` marker short-circuits a
/// re-run, and `seedProvisional` is `INSERT OR IGNORE` so even without the
/// marker a re-seed never clobbers an existing record.
public struct PairedMacMigration: Sendable {
    private let pairedStore: any MobilePairedMacStoring
    private let syncStore: any CmuxSyncStoring

    public init(pairedStore: any MobilePairedMacStoring, syncStore: any CmuxSyncStoring) {
        self.pairedStore = pairedStore
        self.syncStore = syncStore
    }

    /// Seed provisional device records for an account's paired Macs, once.
    /// - Parameters:
    ///   - accountID: Stack user id; the idempotency scope and the paired-Mac
    ///     `stackUserID` filter.
    ///   - teamID: Team scope for the seeded sync records.
    ///   - now: Timestamp for the seeded rows.
    /// - Returns: The number of records seeded (0 if already migrated).
    @discardableResult
    public func runIfNeeded(accountID: String, teamID: String, now: Date = Date()) async throws -> Int {
        if try await syncStore.migrationCompleted(accountID: accountID, teamID: teamID) {
            return 0
        }
        let macs = try await pairedStore.loadAll(stackUserID: accountID)
        var seeded = 0
        let encoder = JSONEncoder()
        for mac in macs {
            let record = Self.provisionalRecord(from: mac)
            let payload = try encoder.encode(record)
            try await syncStore.seedProvisional(
                teamID: teamID,
                collection: devicesSyncCollection,
                recordID: mac.macDeviceID,
                payloadJSON: payload,
                sortKey: mac.lastSeenAt.timeIntervalSince1970 * 1000.0, // ms, matches DO records
                now: now
            )
            seeded += 1
        }
        try await syncStore.markMigrationCompleted(accountID: accountID, teamID: teamID)
        return seeded
    }

    /// Build a provisional `SyncedDeviceRecord` from a paired Mac. A paired Mac
    /// has no per-tag instance split locally, so it maps to a single instance
    /// under the active build tag is unknown — use a single synthetic instance
    /// carrying the Mac's routes so the list renders an attachable row.
    static func provisionalRecord(from mac: MobilePairedMac) -> SyncedDeviceRecord {
        let lastSeenMs = mac.lastSeenAt.timeIntervalSince1970 * 1000.0
        return SyncedDeviceRecord(
            deviceId: mac.macDeviceID,
            platform: "mac",
            displayName: mac.displayName,
            ownerUserId: mac.stackUserID,
            lastSeenAtAtRev: lastSeenMs,
            instances: [
                .init(tag: "default", routes: mac.routes, lastSeenAtAtRev: lastSeenMs),
            ]
        )
    }
}
