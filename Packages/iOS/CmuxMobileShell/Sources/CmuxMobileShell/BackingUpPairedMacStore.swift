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
        teamID: String?,
        now: Date
    ) async throws {
        // Inject the current team (callers go through the no-team convenience
        // overload, so `teamID` arrives nil) so the local row is scoped to the team
        // it was paired under. An explicit teamID (e.g. from restore) wins.
        let team = await resolvedTeam(teamID)
        // Capture the host that is active BEFORE this upsert, so a `markActive`
        // upsert can mirror exactly the two records whose active flag changes (the
        // new host, and the previously-active one now cleared) instead of the whole
        // account. Scoped to the current team — single-active is per (account, team).
        let previouslyActive: MobilePairedMac?
        if markActive, let account = stackUserID, !account.isEmpty {
            previouslyActive = try? await inner.activeMac(stackUserID: account, teamID: team)
        } else {
            previouslyActive = nil
        }
        try await inner.upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: team,
            now: now
        )
        // Mirror to the DO only for a signed-in (account-scoped) host; anonymous
        // local pairings have no per-user collection to back up to. Upload the
        // COMPLETE current record (read back from local) rather than one built from
        // just these params, so an existing customization (name/color/icon) is
        // preserved instead of clobbered with nil.
        guard let account = stackUserID, !account.isEmpty else { return }
        lastSignedInAccount = account
        await uploadCurrentRecord(macDeviceID: macDeviceID, account: account)
        // `markActive` clears the active flag of the account's previously-active
        // host locally; mirror THAT one record too so the backup keeps its
        // single-active invariant — without re-uploading the whole account, which
        // would copy other-team hosts into the selected team's DO (the local rows
        // carry no team id to filter by). See `setActive`.
        if markActive, let previouslyActive, previouslyActive.macDeviceID != macDeviceID {
            await uploadCurrentRecord(macDeviceID: previouslyActive.macDeviceID, account: account)
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

    public func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        await restoreIfNeeded(stackUserID)
        // Scope to the current team (callers pass nil via the convenience overload),
        // so a multi-team user only sees the active team's Macs. NULL-team legacy
        // rows remain visible (the store's `team_id IS ? OR team_id IS NULL` rule).
        let team = await resolvedTeam(teamID)
        return try await inner.loadAll(stackUserID: stackUserID, teamID: team)
    }

    public func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        await restoreIfNeeded(stackUserID)
        let team = await resolvedTeam(teamID)
        return try await inner.activeMac(stackUserID: stackUserID, teamID: team)
    }

    public func setActive(macDeviceID: String) async throws {
        // Resolve the scope and the previously-active host BEFORE the flip, so we can
        // mirror exactly the two records that change. Scoped to the current team
        // (single-active is per (account, team)).
        let account = try? await accountForMac(macDeviceID)
        let team = await teamIDProvider()
        let previouslyActive = (account != nil)
            ? try? await inner.activeMac(stackUserID: account, teamID: team) : nil
        try await inner.setActive(macDeviceID: macDeviceID)
        // setActive flips the active flag for one host (and clears the previously-
        // active one in its scope) without going through `upsert`. Mirror ONLY those
        // two changed records to the DO so a "select host but don't connect, then
        // reinstall" sequence restores the right active host — WITHOUT a whole-
        // account upload, which would copy other-team hosts into the selected team's
        // DO (local rows carry no team id to filter by).
        guard let account else { return }
        lastSignedInAccount = account
        await uploadCurrentRecord(macDeviceID: macDeviceID, account: account)
        if let previouslyActive, previouslyActive.macDeviceID != macDeviceID {
            await uploadCurrentRecord(macDeviceID: previouslyActive.macDeviceID, account: account)
        }
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
        // kept so the next sign-in restores the account's saved hosts.
        //
        // Cancel AND DRAIN any in-flight restore BEFORE wiping. A restore can pass
        // its `Task.isCancelled` check and then suspend inside `inner.upsert`;
        // cancellation does not withdraw that already-queued write. If we wiped
        // first, that upsert could land AFTER the wipe and resurrect the previous
        // account's Macs in the just-emptied store (the sign-out privacy boundary).
        // Awaiting the cancelled tasks guarantees every pending write has completed,
        // so the subsequent wipe is final.
        let draining = cancelInFlightRestoresReturningTasks()
        for task in draining { _ = await task.value }
        try await inner.removeAll()
        restoredScopes.removeAll()
        lastSignedInAccount = nil
    }

    public func cancelInFlightRestores() async {
        _ = cancelInFlightRestoresReturningTasks()
    }

    /// Invalidate in-flight restores and return their handles so the caller can
    /// optionally DRAIN them (await completion) before relying on store state.
    /// Bumps the reset generation so any restore suspended at `await task.value`
    /// bails before memoizing, and cancels the tasks so `PairedMacRestore.run`'s
    /// `Task.isCancelled` checks fire. Does not touch `inner` — sign-out keeps the
    /// per-user rows; only `removeAll` wipes them, after draining.
    private func cancelInFlightRestoresReturningTasks() -> [Task<RestoreOutcome, Never>] {
        resetGeneration &+= 1
        restoredScopes.removeAll()
        let tasks = Array(inFlight.values)
        inFlight.removeAll()
        for task in tasks { task.cancel() }
        return tasks
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
        let restoreTeam = team.isEmpty ? nil : team
        let task: Task<RestoreOutcome, Never>
        if let existing = inFlight[scope] {
            task = existing
        } else {
            let restore = PairedMacRestore(store: inner, backup: backup)
            let created = Task { await restore.run(accountID: account, teamID: restoreTeam) }
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

    /// The team to scope an inner call to: an explicit `teamID` wins (e.g. a restore
    /// that knows its team), else the currently-selected team. (`??` can't take an
    /// async right-hand side, so this is a plain method.)
    private func resolvedTeam(_ teamID: String?) async -> String? {
        if let teamID { return teamID }
        return await teamIDProvider()
    }

    /// Resolve the owning Stack account of a paired Mac, or nil if unknown. Reads
    /// across ALL teams (find-by-id) so a Mac is resolvable regardless of which team
    /// is selected.
    private func accountForMac(_ macDeviceID: String) async throws -> String? {
        let all = try await inner.loadAll(stackUserID: nil)
        return all.first { $0.macDeviceID == macDeviceID }?.stackUserID
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
        let restoreTeam = team.isEmpty ? nil : team

        let task: Task<RestoreOutcome, Never>
        if let existing = inFlight[scope] {
            task = existing
        } else {
            let restore = PairedMacRestore(store: inner, backup: backup)
            let created = Task { await restore.run(accountID: account, teamID: restoreTeam) }
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
