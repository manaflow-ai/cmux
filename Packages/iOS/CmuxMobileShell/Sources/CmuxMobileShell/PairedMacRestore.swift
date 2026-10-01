internal import CMUXMobileCore
public import CmuxMobilePairedMac
public import Foundation
import os

private let pairedMacRestoreLog = Logger(subsystem: "com.cmuxterm.app", category: "PairedMacRestore")

/// Restores a user's backed-up saved hosts into the local
/// ``MobilePairedMacStore`` on sign-in (the mirror image of
/// ``PairedMacMigration``). This is what makes saved hosts and their IPs —
/// including manually typed ones — reappear after a reinstall or a bundle-id
/// change, where the local SQLite container is empty.
///
/// Local stays authoritative: a host present in BOTH places keeps the local copy
/// when local's `lastSeenAt` is at least as recent as the backup's (last-writer-
/// wins by `lastSeenAt`), so a fresh local edit is never clobbered by an older
/// backup. Only hosts missing locally, or whose backup is strictly newer, are
/// written. The active selection is only honored from the backup when the local
/// store has NO active host (the fresh-install case), so restoring never hijacks
/// a host the user is actively using on this device.
public struct PairedMacRestore: Sendable {
    private let store: any MobilePairedMacStoring
    private let backup: any PairedMacBackingUp

    /// Create a restore coordinator over a local paired-Mac store and backup source.
    public init(store: any MobilePairedMacStoring, backup: any PairedMacBackingUp) {
        self.store = store
        self.backup = backup
    }

    /// Merge the user's backup into the local store. A fetch failure leaves the
    /// local store untouched and reports `completed: false` so the caller can
    /// retry; a successful fetch (even of an empty list) reports `completed:
    /// true`.
    /// - Parameters:
    ///   - teamID: the Stack team this restore is for. The backup fetch is
    ///     already server-scoped to that team (`X-Cmux-Team-Id`), so every restored
    ///     row is stamped with it; this is what scopes the local list per team. `nil`
    ///     when no team is selected (rows stay team-less / visible everywhere).
    ///   - onResolvedBackupTeam: called once, AFTER the merge, when the
    ///     snapshot carries the worker's echoed resolved team — with one echo
    ///     per snapshot record (not just the ones written locally: each record
    ///     lives in that team's backup regardless of the merge outcome). Every
    ///     echo also reports whether a local row for the pairing survived the
    ///     merge and under which team it is actually stored, plus the record's
    ///     creation time — so the owner can persist the mapping against the
    ///     ROW's real scope and can tell a post-forget revival from a stale
    ///     copy.
    @discardableResult
    public func run(
        accountID: String,
        teamID: String? = nil,
        now: Date = Date(),
        boundary: PairedMacRestoreBoundary? = nil,
        boundaryGeneration: UInt64? = nil,
        suppressions: [PairedMacRestoreSuppression] = [],
        onResolvedBackupTeam: (@Sendable ([PairedMacRestoreEcho], String) async -> Void)? = nil
    ) async -> RestoreOutcome {
        func isCurrent() -> Bool {
            guard !Task.isCancelled else { return false }
            guard let boundary, let boundaryGeneration else { return true }
            return boundary.isCurrent(boundaryGeneration)
        }

        guard let snapshot = await backup.fetchSnapshot(teamID: teamID, expectedUserID: accountID) else {
            return RestoreOutcome(completed: false, restored: 0)
        }
        let restoreCompleted = !snapshot.requiresMigrationRetry
        // Sign-out (or any wipe) can race this restore: if the owning task was
        // cancelled while the network fetch was suspended, do NOT write the
        // previous account's Macs back into the just-emptied local store. Report
        // `completed: false` so the caller does not memoize a non-restore.
        if !isCurrent() {
            return RestoreOutcome(completed: false, restored: 0)
        }
        func canonicalPairingID(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let identity = MobilePairedMac.pairingIdentity(from: trimmed)
            return MobilePairedMac.pairingID(
                macDeviceID: identity.macDeviceID,
                instanceTag: identity.instanceTag
            )
        }
        // Server tombstones were written only by the retired legacy-delete
        // behavior. They no longer remove or suppress local paired-Mac rows.
        // Locally pending deletes remain authoritative until their outbox
        // flushes — UNLESS the record is a REVIVAL: a server write newer than
        // the suppressing tombstone means another device re-paired the Mac
        // after this phone's forget, and the record must merge normally (the
        // owner retires the tombstone from the post-merge echo). A record
        // survives only when EVERY covering suppression sees it as revived.
        let normalizedSuppressions = suppressions.compactMap { suppression in
            canonicalPairingID(suppression.pairingID).map {
                PairedMacRestoreSuppression(pairingID: $0, stampMs: suppression.stampMs)
            }
        }
        let pendingDeleteIDs = Set(normalizedSuppressions.map(\.pairingID))
        let liveRecords = snapshot.records.filter { record in
            let pairingID = MobilePairedMac.pairingID(
                macDeviceID: cmxCanonicalDeviceID(record.macDeviceID),
                instanceTag: record.instanceTag
            )
            return !normalizedSuppressions.contains { suppression in
                suppression.covers(pairingID: pairingID)
                    && !suppression.treatsAsRevived(serverUpdatedAtMs: record.serverUpdatedAtMs)
            }
        }
        guard !liveRecords.isEmpty || !pendingDeleteIDs.isEmpty else {
            return RestoreOutcome(completed: restoreCompleted, restored: 0)
        }

        let localBeforePendingDeletes = (try? await store.loadAll(
            stackUserID: accountID,
            teamID: teamID
        )) ?? []
        // The fetch is not the only sign-out window: re-check after the load too,
        // before we start writing (a wipe between fetch and load must not be
        // overwritten with the old account's Macs).
        if !isCurrent() {
            return RestoreOutcome(completed: false, restored: 0)
        }
        for pairingID in pendingDeleteIDs {
            if !isCurrent() {
                return RestoreOutcome(completed: false, restored: 0)
            }
            do {
                let identity = MobilePairedMac.pairingIdentity(from: pairingID)
                if let instanceTag = identity.instanceTag {
                    try await store.remove(
                        macDeviceID: identity.macDeviceID,
                        instanceTag: instanceTag,
                        stackUserID: accountID,
                        teamID: teamID
                    )
                } else {
                    try await store.remove(
                        macDeviceID: identity.macDeviceID,
                        stackUserID: accountID,
                        teamID: teamID
                    )
                }
            } catch {
                pairedMacRestoreLog.warning(
                    "failed to apply pending paired mac delete \(pairingID, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        let local = pendingDeleteIDs.isEmpty
            ? localBeforePendingDeletes
            : ((try? await store.loadAll(stackUserID: accountID, teamID: teamID)) ?? [])
        if !isCurrent() {
            return RestoreOutcome(completed: false, restored: 0)
        }
        var localByID: [String: MobilePairedMac] = [:]
        for mac in local { localByID[mac.id] = mac }
        // On a fresh install (no local active host) honor the backup's active
        // flag so auto-reconnect targets the last host; otherwise never disturb
        // the device's current active selection.
        let hasLocalActive = local.contains { $0.isActive }

        var restored = 0
        for record in liveRecords {
            // Re-check before EVERY write: a sign-out wipe can land between any two
            // upserts, and writes after it would reinsert the previous account's
            // Macs into the emptied store. Stop the moment we are cancelled.
            if !isCurrent() {
                return RestoreOutcome(completed: false, restored: restored)
            }
            let canonicalDeviceID = cmxCanonicalDeviceID(record.macDeviceID)
            let pairingID = MobilePairedMac.pairingID(
                macDeviceID: canonicalDeviceID,
                instanceTag: record.instanceTag
            )
            let backupSeconds = record.lastSeenAt / 1000.0
            if let existing = localByID[pairingID],
               existing.lastSeenAt.timeIntervalSince1970 >= backupSeconds {
                continue // local is at least as fresh: keep it (local authoritative)
            }
            // Active flag policy: when this record already exists locally we are
            // only refreshing its route/name (the backup is fresher), so PRESERVE
            // its current local active flag — otherwise a route refresh of the
            // active Mac (e.g. `refreshFromBackup` right before reconnect/
            // aggregation) would silently deactivate it and lose the user's
            // selection. For a record missing locally, honor the backup's active
            // only on a fresh install (no local active host); never hijack an
            // existing active selection.
            let markActive: Bool
            if let existing = localByID[pairingID] {
                markActive = existing.isActive
            } else {
                markActive = hasLocalActive ? false : record.isActive
            }
            do {
                let backupDate = Date(timeIntervalSince1970: backupSeconds)
                let restoredThisRecord = try await store.upsertIfNewer(
                    macDeviceID: canonicalDeviceID,
                    displayName: record.displayName,
                    routes: record.routes,
                    instanceTag: record.instanceTag,
                    customName: record.customName,
                    customColor: record.customColor,
                    customIcon: record.customIcon,
                    markActive: markActive,
                    stackUserID: accountID,
                    teamID: teamID,
                    now: backupDate
                )
                guard restoredThisRecord else { continue }
                if !isCurrent() {
                    if localByID[pairingID] == nil {
                        try? await store.remove(
                            macDeviceID: canonicalDeviceID,
                            instanceTag: record.instanceTag,
                            stackUserID: accountID,
                            teamID: teamID
                        )
                    }
                    return RestoreOutcome(completed: false, restored: restored)
                }
                if !isCurrent() {
                    return RestoreOutcome(completed: false, restored: restored)
                }
                restored += 1
            } catch {
                pairedMacRestoreLog.warning(
                    "failed to restore paired mac \(canonicalDeviceID, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        if restored > 0 {
            pairedMacRestoreLog.info("restored \(restored, privacy: .public) paired mac(s) from backup")
        }
        // The echo fires AFTER the merge so each record can report the RETAINED
        // local row's actual scope: LWW can keep a newer team-less local row
        // without re-stamping it into this restore's team, and a mapping keyed
        // by the restore team would never be found by that row's later forget.
        if let onResolvedBackupTeam, let resolvedTeamID = snapshot.resolvedTeamID,
           !snapshot.records.isEmpty {
            let localAfter = (try? await store.loadAll(
                stackUserID: accountID,
                teamID: teamID
            )) ?? []
            var retainedTeams: [String: String?] = [:]
            for mac in localAfter {
                // updateValue, not the subscript: retention of a TEAM-LESS row
                // must store a present entry whose value is nil, never read as
                // ambiguous double-optional assignment.
                retainedTeams.updateValue(mac.teamID, forKey: mac.id)
            }
            let echoes = snapshot.records.map { record -> PairedMacRestoreEcho in
                let pairingID = MobilePairedMac.pairingID(
                    macDeviceID: cmxCanonicalDeviceID(record.macDeviceID),
                    instanceTag: record.instanceTag
                )
                let retained = retainedTeams[pairingID]
                return PairedMacRestoreEcho(
                    pairingID: pairingID,
                    hasRetainedLocalRow: retained != nil,
                    retainedRowTeamID: retained ?? nil,
                    serverUpdatedAtMs: record.serverUpdatedAtMs
                )
            }
            await onResolvedBackupTeam(echoes, resolvedTeamID)
        }
        return RestoreOutcome(completed: restoreCompleted, restored: restored)
    }
}

/// One snapshot record's routing echo (see ``PairedMacRestore/run``).
public struct PairedMacRestoreEcho: Sendable {
    /// The record's composite pairing id.
    public let pairingID: String
    /// Whether a local row for this pairing exists after the merge.
    public let hasRetainedLocalRow: Bool
    /// The retained local row's OWN team (nil = a team-less row); meaningful
    /// only when ``hasRetainedLocalRow``.
    public let retainedRowTeamID: String?
    /// SERVER-authored last-write time (ms since epoch): a record the server
    /// wrote AFTER a forget is a revival, not a stale copy. `nil` for
    /// snapshots from workers that predate the field.
    public let serverUpdatedAtMs: Double?

    public init(
        pairingID: String,
        hasRetainedLocalRow: Bool,
        retainedRowTeamID: String?,
        serverUpdatedAtMs: Double?
    ) {
        self.pairingID = pairingID
        self.hasRetainedLocalRow = hasRetainedLocalRow
        self.retainedRowTeamID = retainedRowTeamID
        self.serverUpdatedAtMs = serverUpdatedAtMs
    }
}

/// One tombstone the restore must honor: records covered by it are withheld
/// from the merge unless the server wrote them AFTER the tombstone.
public struct PairedMacRestoreSuppression: Sendable {
    /// The forgotten pairing; a TAG-LESS id is the device-wide wildcard and
    /// covers every tag of its device.
    public let pairingID: String
    /// The tombstone's creation time (ms since epoch); 0 = no boundary is
    /// known (legacy records), which suppresses unconditionally.
    public let stampMs: Double

    public init(pairingID: String, stampMs: Double) {
        self.pairingID = pairingID
        self.stampMs = stampMs
    }

    /// Whether this tombstone covers the pairing (exact, or any tag of the
    /// device for a tag-less wildcard).
    public func covers(pairingID other: String) -> Bool {
        if pairingID == other { return true }
        let own = MobilePairedMac.pairingIdentity(from: pairingID)
        guard own.instanceTag == nil else { return false }
        let identity = MobilePairedMac.pairingIdentity(from: other)
        return cmxCanonicalDeviceID(identity.macDeviceID)
            == cmxCanonicalDeviceID(own.macDeviceID)
    }

    /// Whether a record the server last wrote at `serverUpdatedAtMs` counts as
    /// a post-forget revival for this tombstone: STRICTLY after the stamp,
    /// never earlier. Forgetting a currently-online Mac whose backup was
    /// route-mirrored seconds earlier is the COMMON case, so any allowance
    /// accepting pre-forget writes would bypass suppression for it. The
    /// residual (phone clock behind the server by more than NTP drift) fails
    /// in the recoverable direction: the revival is deleted ONCE, the other
    /// device's next mirror re-uploads it with a fresh server stamp, and the
    /// following restore classifies it correctly.
    public func treatsAsRevived(serverUpdatedAtMs: Double?) -> Bool {
        guard stampMs > 0, let serverUpdatedAtMs else { return false }
        return serverUpdatedAtMs > stampMs
    }
}
