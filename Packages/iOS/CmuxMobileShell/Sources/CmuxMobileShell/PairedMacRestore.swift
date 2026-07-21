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
    /// - Parameter teamID: the Stack team this restore is for. The backup fetch is
    ///   already server-scoped to that team (`X-Cmux-Team-Id`), so every restored
    ///   row is stamped with it; this is what scopes the local list per team. `nil`
    ///   when no team is selected (rows stay team-less / visible everywhere).
    @discardableResult
    public func run(
        accountID: String,
        teamID: String? = nil,
        now: Date = Date(),
        boundary: PairedMacRestoreBoundary? = nil,
        boundaryGeneration: UInt64? = nil,
        locallyDeletedMacDeviceIDs: Set<String> = []
    ) async -> RestoreOutcome {
        func isCurrent() -> Bool {
            guard !Task.isCancelled else { return false }
            guard let boundary, let boundaryGeneration else { return true }
            return boundary.isCurrent(boundaryGeneration)
        }

        guard let snapshot = await backup.fetchSnapshot(teamID: teamID, expectedUserID: accountID) else {
            return RestoreOutcome(completed: false, restored: 0)
        }
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
        let tombstoneIDs = Set(snapshot.deletedMacDeviceIDs.compactMap(canonicalPairingID))
            .union(locallyDeletedMacDeviceIDs.compactMap(canonicalPairingID))
        let liveRecords = snapshot.records.filter { record in
            !tombstoneIDs.contains(MobilePairedMac.pairingID(
                macDeviceID: record.macDeviceID,
                instanceTag: record.instanceTag
            ))
        }
        guard !liveRecords.isEmpty || !tombstoneIDs.isEmpty else {
            return RestoreOutcome(completed: true, restored: 0)
        }

        let localBeforeTombstones = (try? await store.loadAll(stackUserID: accountID, teamID: teamID)) ?? []
        // The fetch is not the only sign-out window: re-check after the load too,
        // before we start writing (a wipe between fetch and load must not be
        // overwritten with the old account's Macs).
        if !isCurrent() {
            return RestoreOutcome(completed: false, restored: 0)
        }
        for pairingID in tombstoneIDs {
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
                    "failed to apply paired mac tombstone \(pairingID, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        let local = tombstoneIDs.isEmpty
            ? localBeforeTombstones
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
        return RestoreOutcome(completed: true, restored: restored)
    }
}
