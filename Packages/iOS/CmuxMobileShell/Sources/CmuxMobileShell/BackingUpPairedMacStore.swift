public import CMUXMobileCore
public import CmuxMobilePairedMac
public import Foundation

/// A ``MobilePairedMacStoring`` decorator that keeps the per-user Durable Object
/// backup in sync with the local store, and restores from it on sign-in. Wraps
/// the real ``MobilePairedMacStore`` at the composition root behind the
/// ``MobilePairedMacBackup`` flag, so EVERY paired-Mac mutation (route refresh,
/// pairing, rename, forget) flows through one seam — no per-call-site patching.
///
/// - Writes (`upsert`/`remove`) forward to the local store first (it stays
///   authoritative), then mirror the change to the DO best-effort.
/// - Reads (`loadAll`/`activeMac`) trigger a one-time restore for the signed-in
///   account before returning, so a fresh install / post-upgrade launch shows
///   the user's saved hosts as soon as the host list is read.
/// - `removeAll` (the sign-out wipe) is NOT mirrored: signing out must not delete
///   the account's server backup, or the next sign-in would restore nothing.
public actor BackingUpPairedMacStore: MobilePairedMacStoring {
    private let inner: any MobilePairedMacStoring
    private let backup: any PairedMacBackingUp
    /// Accounts whose restore has already run this process, so a restore happens
    /// at most once per account per launch (not on every list read).
    private var restoredAccounts: Set<String> = []

    public init(inner: any MobilePairedMacStoring, backup: any PairedMacBackingUp) {
        self.inner = inner
        self.backup = backup
    }

    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        now: Date
    ) async throws {
        try await inner.upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            markActive: markActive,
            stackUserID: stackUserID,
            now: now
        )
        // Mirror to the DO only for a signed-in (account-scoped) host; anonymous
        // local pairings have no per-user collection to back up to. createdAt is
        // not known at this seam, so it reuses `now`; the server ignores it in
        // its shape compare, so this never churns the backup rev.
        guard stackUserID?.isEmpty == false else { return }
        let ms = now.timeIntervalSince1970 * 1000.0
        await backup.upload(ops: [.upsert(PairedMacBackupRecord(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            createdAt: ms,
            lastSeenAt: ms,
            isActive: markActive
        ))])
    }

    public func loadAll(stackUserID: String?) async throws -> [MobilePairedMac] {
        await restoreIfNeeded(stackUserID)
        return try await inner.loadAll(stackUserID: stackUserID)
    }

    public func activeMac(stackUserID: String?) async throws -> MobilePairedMac? {
        await restoreIfNeeded(stackUserID)
        return try await inner.activeMac(stackUserID: stackUserID)
    }

    public func setActive(macDeviceID: String) async throws {
        // Forward only. The active flag is carried on the record and re-mirrored
        // by the next `upsert` (route refreshes pass the current active state),
        // so a dedicated backup write here is unnecessary.
        try await inner.setActive(macDeviceID: macDeviceID)
    }

    public func remove(macDeviceID: String) async throws {
        try await inner.remove(macDeviceID: macDeviceID)
        await backup.upload(ops: [.delete(macDeviceID: macDeviceID)])
    }

    public func removeAll() async throws {
        // Sign-out wipe: clear local only. The server backup is intentionally
        // kept so the next sign-in restores the account's saved hosts.
        try await inner.removeAll()
    }

    /// Run the backup restore once per signed-in account this launch. Marked
    /// before the await so concurrent reads do not double-restore.
    private func restoreIfNeeded(_ stackUserID: String?) async {
        guard let account = stackUserID, !account.isEmpty, !restoredAccounts.contains(account) else {
            return
        }
        restoredAccounts.insert(account)
        await PairedMacRestore(store: inner, backup: backup).run(accountID: account)
    }
}
