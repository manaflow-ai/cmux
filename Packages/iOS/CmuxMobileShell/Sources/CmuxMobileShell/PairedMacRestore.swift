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
public enum PairedMacRestore {
    /// Merge the user's backup into `store`. Best-effort: a fetch failure leaves
    /// the local store untouched (it returns 0). Returns the number of records
    /// written, for logging/tests.
    @discardableResult
    public static func run(
        into store: any MobilePairedMacStoring,
        from backup: any PairedMacBackingUp,
        accountID: String,
        now: Date = Date()
    ) async -> Int {
        let remote = await backup.fetchAll()
        guard !remote.isEmpty else { return 0 }

        let local = (try? await store.loadAll(stackUserID: accountID)) ?? []
        var localByID: [String: MobilePairedMac] = [:]
        for mac in local { localByID[mac.macDeviceID] = mac }
        // On a fresh install (no local active host) honor the backup's active
        // flag so auto-reconnect targets the last host; otherwise never disturb
        // the device's current active selection.
        let hasLocalActive = local.contains { $0.isActive }

        var restored = 0
        for record in remote {
            let backupSeconds = record.lastSeenAt / 1000.0
            if let existing = localByID[record.macDeviceID],
               existing.lastSeenAt.timeIntervalSince1970 >= backupSeconds {
                continue // local is at least as fresh: keep it (local authoritative)
            }
            do {
                try await store.upsert(
                    macDeviceID: record.macDeviceID,
                    displayName: record.displayName,
                    routes: record.routes,
                    markActive: hasLocalActive ? false : record.isActive,
                    stackUserID: accountID,
                    now: Date(timeIntervalSince1970: backupSeconds)
                )
                restored += 1
            } catch {
                pairedMacRestoreLog.warning(
                    "failed to restore paired mac \(record.macDeviceID, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        if restored > 0 {
            pairedMacRestoreLog.info("restored \(restored, privacy: .public) paired mac(s) from backup")
        }
        return restored
    }
}
