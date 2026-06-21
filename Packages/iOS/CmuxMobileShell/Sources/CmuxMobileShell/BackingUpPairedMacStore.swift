public import CMUXMobileCore
public import CmuxMobilePairedMac
public import Foundation

/// A paired-Mac store that can re-pull the authoritative backup on demand,
/// instead of only once-per-launch at sign-in. Multi-Mac aggregation needs this:
/// a secondary Mac that relaunched on a new port republishes its route to the
/// backup, but the once-per-launch restore won't pick it up, so the iPhone's
/// stored route goes stale and the read-only secondary fetch dials a dead port.
/// Refreshing from the backup right before aggregating keeps secondary routes
/// current (LWW by `lastSeenAt`, so the live foreground route is never clobbered).
public protocol PairedMacBackupRefreshing: Sendable {
    /// Force a backup re-fetch + LWW merge for the signed-in scope, bypassing the
    /// once-per-launch restore memo. Best-effort; never throws.
    func refreshFromBackup(stackUserID: String?) async

    /// Cancel every in-flight restore/refresh so a fetch suspended across a
    /// sign-out / account switch cannot resume and write the previous account's
    /// Macs (with the live token possibly now scoped to a different user). Does
    /// NOT wipe the local store — sign-out retains the per-user rows for a
    /// same-account re-sign-in restore. Best-effort; never throws.
    func cancelInFlightRestores() async
}

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
public actor BackingUpPairedMacStore: MobilePairedMacStoring, PairedMacBackupRefreshing {
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
    /// Bumped by every `removeAll()` (sign-out wipe). A restore captures it before
    /// awaiting its task and re-checks after: a restore that completed/resumed
    /// across a wipe must NOT memoize `restoredScopes` (which would make a
    /// same-launch re-sign-in skip the restore and show an empty list) or clobber
    /// a post-wipe `inFlight` entry.
    private var resetGeneration = 0

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
            // Upload the COMPLETE current record (read back from local) rather than
            // a record built from just these params, so an existing customization
            // (name/color/icon) is preserved instead of clobbered with nil.
            await uploadCurrentRecord(macDeviceID: macDeviceID, account: account)
        }
    }

    public func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        now: Date
    ) async throws {
        try await inner.setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            now: now
        )
        // Mirror the customization to the DO so it appears on the user's other
        // signed-in devices. Best-effort, like every other backup write.
        guard let account = try? await accountForMac(macDeviceID) else { return }
        lastSignedInAccount = account
        await uploadCurrentRecord(macDeviceID: macDeviceID, account: account)
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
        // Cancel in-flight restores so a backup fetch suspended across this wipe
        // cannot resume and re-upsert the previous account's Macs into the just-
        // emptied local store (sign-out privacy boundary). `PairedMacRestore.run`
        // checks `Task.isCancelled` after its fetch and skips the writes.
        await cancelInFlightRestores()
        lastSignedInAccount = nil
    }

    public func cancelInFlightRestores() async {
        // Bump the reset generation so any restore already past its cancellation
        // checks (suspended at `await task.value`) still bails before memoizing,
        // and cancel the tasks so `PairedMacRestore.run`'s `Task.isCancelled`
        // checks fire. Does not touch `inner` — sign-out keeps the per-user rows.
        resetGeneration &+= 1
        restoredScopes.removeAll()
        for (_, task) in inFlight { task.cancel() }
        inFlight.removeAll()
    }

    /// Force a backup re-fetch + LWW merge for the signed-in scope, ignoring the
    /// once-per-launch memo. Used before multi-Mac aggregation so a secondary
    /// Mac that relaunched on a new port has its route refreshed locally before
    /// the read-only workspace fetch dials it. Best-effort; failures leave the
    /// local store untouched (``PairedMacRestore`` no-ops on a failed fetch).
    public func refreshFromBackup(stackUserID: String?) async {
        guard let account = stackUserID, !account.isEmpty else { return }
        lastSignedInAccount = account
        // Coalesce with any in-flight restore for this scope so we never run two
        // merges concurrently against the same store.
        let team = (await teamIDProvider()) ?? ""
        let scope = "\(account)\u{0}\(team)"
        let task: Task<RestoreOutcome, Never>
        if let existing = inFlight[scope] {
            task = existing
        } else {
            let restore = PairedMacRestore(store: inner, backup: backup)
            let created = Task { await restore.run(accountID: account) }
            inFlight[scope] = created
            task = created
        }
        let generation = resetGeneration
        let outcome = await task.value
        // A sign-out wipe across the await already cleared inFlight/restoredScopes;
        // do not re-touch them (clobbering a post-wipe inFlight entry, or memoizing
        // a scope the wipe removed and suppressing a same-launch re-sign-in restore).
        guard resetGeneration == generation else { return }
        inFlight[scope] = nil
        if outcome.completed { restoredScopes.insert(scope) }
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
    ///
    /// SCOPE LIMITATION: the backup DO is per-(account, team) but the local
    /// `MobilePairedMacStore` rows carry only `stackUserID`, so this mirrors the
    /// account's whole set into whichever team the backup client currently targets.
    /// For a solo account or a single-team user (team == account) that is exactly
    /// right. A genuine multi-team user who switches teams and then re-uploads can
    /// copy another team's hosts into the selected team's backup. Closing that gap
    /// cleanly needs a `team_id` column on the store rows (a v3 migration) so the
    /// mirror/restore set can be filtered by team; tracked as a follow-up.
    private func mirrorAccountScope(_ account: String) async {
        guard let macs = try? await inner.loadAll(stackUserID: account), !macs.isEmpty else { return }
        await backup.upload(ops: macs.map { .upsert(Self.backupRecord(from: $0)) })
    }

    /// Build the COMPLETE backup record for a Mac from the local row, so every
    /// upload carries displayName, routes, active AND the user customizations —
    /// otherwise a route-refresh upload would clobber the synced customizations
    /// with `nil`. Timestamps are ms since epoch (the backup wire format).
    static func backupRecord(from mac: MobilePairedMac) -> PairedMacBackupRecord {
        PairedMacBackupRecord(
            macDeviceID: mac.macDeviceID,
            displayName: mac.displayName,
            routes: mac.routes,
            createdAt: mac.createdAt.timeIntervalSince1970 * 1000.0,
            lastSeenAt: mac.lastSeenAt.timeIntervalSince1970 * 1000.0,
            isActive: mac.isActive,
            customName: mac.customName,
            customColor: mac.customColor,
            customIcon: mac.customIcon
        )
    }

    /// Upload the current complete record for one Mac (read back from the local
    /// store so customizations are preserved). Best-effort.
    private func uploadCurrentRecord(macDeviceID: String, account: String) async {
        guard let mac = (try? await inner.loadAll(stackUserID: account))?
            .first(where: { $0.macDeviceID == macDeviceID }) else { return }
        await backup.upload(ops: [.upsert(Self.backupRecord(from: mac))])
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
        let generation = resetGeneration
        let outcome = await task.value
        // A sign-out wipe across the await already cleared inFlight/restoredScopes;
        // do not re-touch them (we'd clobber a post-wipe inFlight entry or memoize a
        // scope the wipe removed, suppressing a same-launch re-sign-in restore).
        guard resetGeneration == generation else { return }
        inFlight[scope] = nil
        if outcome.completed { restoredScopes.insert(scope) }
    }
}
