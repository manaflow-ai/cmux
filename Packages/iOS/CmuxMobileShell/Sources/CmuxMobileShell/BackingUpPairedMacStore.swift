public import CMUXMobileCore
public import CmuxMobilePairedMac
public import Foundation

/// A ``MobilePairedMacStoring`` decorator that keeps the per-user Durable Object
/// backup in sync with the local store, and restores from it on sign-in. Wraps
/// the real ``MobilePairedMacStore`` at the composition root behind the
/// ``MobilePairedMacBackup`` flag, so EVERY paired-Mac mutation (route refresh,
/// pairing, rename, forget, active switch) flows through one seam — no per-call-
/// site patching.
///
/// - Writes (`upsert`/`remove`/`setActive`) forward to the local store first (it
///   stays authoritative), then mirror the change to the DO best-effort.
/// - Reads (`loadAll`/`activeMac`) trigger a one-time restore for the signed-in
///   (account, team) scope before returning, so a fresh install / post-upgrade
///   launch shows the user's saved hosts as soon as the host list is read.
/// - `removeAll` (the sign-out wipe) is NOT mirrored (signing out must not delete
///   the account's server backup) and resets the restore memo so a same-launch
///   re-sign-in restores again.
public actor BackingUpPairedMacStore: MobilePairedMacStoring {
    private let inner: any MobilePairedMacStoring
    private let backup: any PairedMacBackingUp
    /// The current team id, read live so the restore is scoped per (account,
    /// team): the backup DO is per-team, so switching teams must re-restore.
    private let teamIDProvider: @Sendable () async -> String?

    /// (account, team) scopes whose restore has SUCCESSFULLY completed this
    /// process, so a restore runs at most once per scope — but a fetch failure
    /// is not memoized, so a transient failure retries on the next read.
    private var restoredScopes: Set<String> = []
    /// In-flight restores keyed by scope, so concurrent reads await the SAME
    /// merge instead of one slipping past `restoredScopes` and reading a
    /// half-restored store.
    private var inFlight: [String: Task<RestoreOutcome, Never>] = [:]
    /// The most recent signed-in account seen on a read/write, so `remove` (which
    /// has no account parameter) only mirrors deletes while signed in.
    private var lastSignedInAccount: String?

    public init(
        inner: any MobilePairedMacStoring,
        backup: any PairedMacBackingUp,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.inner = inner
        self.backup = backup
        self.teamIDProvider = teamIDProvider
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
        // local pairings have no per-user collection to back up to.
        guard let account = stackUserID, !account.isEmpty else { return }
        lastSignedInAccount = account
        // `markActive: true` clears the active flag of the account's OTHER hosts
        // locally, so mirror the whole scope to keep the backup's single-active
        // invariant; a plain (non-active) upsert only needs to mirror itself.
        if markActive {
            await mirrorAccountScope(account)
        } else {
            let ms = now.timeIntervalSince1970 * 1000.0
            await backup.upload(ops: [.upsert(PairedMacBackupRecord(
                macDeviceID: macDeviceID,
                displayName: displayName,
                routes: routes,
                createdAt: ms,
                lastSeenAt: ms,
                isActive: false
            ))])
        }
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
        try await inner.setActive(macDeviceID: macDeviceID)
        // setActive flips the active flag for one host (and clears the others in
        // its scope) without going through `upsert`, so mirror the affected
        // scope to the DO. Otherwise a "select host but don't connect, then
        // reinstall" sequence restores a stale active host.
        guard let account = try? await accountForMac(macDeviceID) else { return }
        lastSignedInAccount = account
        await mirrorAccountScope(account)
    }

    public func remove(macDeviceID: String) async throws {
        try await inner.remove(macDeviceID: macDeviceID)
        // Only mirror the delete while signed in; an anonymous removal has no
        // per-user backup to delete and would just fail auth and log noise.
        guard lastSignedInAccount != nil else { return }
        await backup.upload(ops: [.delete(macDeviceID: macDeviceID)])
    }

    public func removeAll() async throws {
        // Sign-out wipe: clear local only. The server backup is intentionally
        // kept so the next sign-in restores the account's saved hosts. Reset the
        // restore memo (and any in-flight restore) so a same-launch re-sign-in
        // restores again rather than reading the just-emptied store.
        try await inner.removeAll()
        restoredScopes.removeAll()
        inFlight.removeAll()
        lastSignedInAccount = nil
    }

    // MARK: - Internals

    /// Resolve the owning Stack account of a paired Mac, or nil if unknown.
    private func accountForMac(_ macDeviceID: String) async throws -> String? {
        let all = try await inner.loadAll(stackUserID: nil)
        return all.first { $0.macDeviceID == macDeviceID }?.stackUserID
    }

    /// Upload every host in an account's scope as upserts, with accurate fields
    /// read back from the local store. Unchanged hosts are no-ops server-side
    /// (shape-aware equality), so this only emits deltas for what actually
    /// changed (e.g. the flipped active flag).
    private func mirrorAccountScope(_ account: String) async {
        guard let macs = try? await inner.loadAll(stackUserID: account), !macs.isEmpty else { return }
        let ops: [PairedMacBackupOp] = macs.map { mac in
            .upsert(PairedMacBackupRecord(
                macDeviceID: mac.macDeviceID,
                displayName: mac.displayName,
                routes: mac.routes,
                createdAt: mac.createdAt.timeIntervalSince1970 * 1000.0,
                lastSeenAt: mac.lastSeenAt.timeIntervalSince1970 * 1000.0,
                isActive: mac.isActive
            ))
        }
        await backup.upload(ops: ops)
    }

    /// Run the backup restore once per signed-in (account, team) scope this
    /// launch. Concurrent reads share one in-flight restore; only a SUCCESSFUL
    /// fetch is memoized, so a transient failure retries on the next read.
    private func restoreIfNeeded(_ stackUserID: String?) async {
        guard let account = stackUserID, !account.isEmpty else { return }
        lastSignedInAccount = account
        let team = (await teamIDProvider()) ?? ""
        let scope = "\(account)\u{0}\(team)"
        if restoredScopes.contains(scope) { return }

        let task: Task<RestoreOutcome, Never>
        if let existing = inFlight[scope] {
            task = existing
        } else {
            let restore = PairedMacRestore(store: inner, backup: backup)
            let created = Task { await restore.run(accountID: account) }
            inFlight[scope] = created
            task = created
        }
        let outcome = await task.value
        inFlight[scope] = nil
        if outcome.completed { restoredScopes.insert(scope) }
    }
}
