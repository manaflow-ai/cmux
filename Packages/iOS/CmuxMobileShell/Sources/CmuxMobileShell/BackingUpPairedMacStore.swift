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
    private let restoreBoundary: PairedMacRestoreBoundary
    private let pendingDeleteStore: any PairedMacPendingDeleteStoring
    private var pendingDeleteIDsByScope: [String: Set<String>] = [:]
    /// Bumped by every `removeAll()` (sign-out wipe). A restore captures it before
    /// awaiting its task and re-checks after: a restore that completed/resumed
    /// across a wipe must NOT memoize `restoredScopes` (which would make a
    /// same-launch re-sign-in skip the restore and show an empty list) or clobber
    /// a post-wipe `inFlight` entry.
    private var resetGeneration = 0

    /// Wrap a local paired-Mac store with a backup transport.
    public init(
        inner: any MobilePairedMacStoring,
        backup: any PairedMacBackingUp,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil },
        restoreBoundary: PairedMacRestoreBoundary = PairedMacRestoreBoundary(),
        pendingDeleteStore: any PairedMacPendingDeleteStoring = InMemoryPairedMacPendingDeleteStore()
    ) {
        self.inner = inner
        self.backup = backup
        self.teamIDProvider = teamIDProvider
        self.restoreBoundary = restoreBoundary
        self.pendingDeleteStore = pendingDeleteStore
    }

    /// Upsert a paired Mac locally, then mirror the changed backup records.
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
        let existedBeforeUpsert: Bool
        if markActive, let account = stackUserID, !account.isEmpty {
            let existing = (try? await inner.loadAll(stackUserID: account, teamID: team)) ?? []
            previouslyActive = existing.first { $0.isActive }
            existedBeforeUpsert = existing.contains { $0.macDeviceID == macDeviceID }
        } else {
            previouslyActive = nil
            existedBeforeUpsert = true
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
        // local pairings have no per-user collection to back up to. Routine route
        // and active-state uploads are intentionally non-authoritative for the
        // customization fields: a stale device must not erase a newer rename/color
        // selected on another device. Only `setCustomization` sends custom keys.
        guard let account = stackUserID, !account.isEmpty else { return }
        lastSignedInAccount = account
        let allowsTombstoneRevive = await clearPendingDelete(macDeviceID: macDeviceID, account: account, teamID: team)
            || (markActive && !existedBeforeUpsert)
        await uploadCurrentRecord(
            macDeviceID: macDeviceID,
            account: account,
            teamID: team,
            includesCustomizations: false,
            allowTombstoneRevive: allowsTombstoneRevive
        )
        // `markActive` clears the active flag of the account's previously-active
        // host locally; mirror THAT one record too so the backup keeps its
        // single-active invariant — without re-uploading the whole account, which
        // would copy other-team hosts into the selected team's DO (the local rows
        // carry no team id to filter by). See `setActive`.
        if markActive, let previouslyActive, previouslyActive.macDeviceID != macDeviceID {
            await uploadCurrentRecord(
                macDeviceID: previouslyActive.macDeviceID,
                account: account,
                teamID: team,
                includesCustomizations: false
            )
        }
    }

    /// Persist local customizations, then mirror the complete record to backup.
    public func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        now: Date
    ) async throws {
        let team = await teamIDProvider()
        let account = try? await accountForMac(macDeviceID, teamID: team)
        try await setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: account,
            teamID: team,
            now: now
        )
    }

    /// Load paired Macs after ensuring the signed-in account/team backup was restored.
    public func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        await restoreIfNeeded(stackUserID)
        // Scope to the current team (callers pass nil via the convenience overload),
        // so a multi-team user only sees the active team's Macs. NULL-team legacy
        // rows remain visible (the store's `team_id IS ? OR team_id IS NULL` rule).
        let team = await resolvedTeam(teamID)
        return try await inner.loadAll(stackUserID: stackUserID, teamID: team)
    }

    /// Load the active Mac after ensuring the signed-in account/team backup was restored.
    public func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        await restoreIfNeeded(stackUserID)
        let team = await resolvedTeam(teamID)
        return try await inner.activeMac(stackUserID: stackUserID, teamID: team)
    }

    /// Mark one paired Mac active and mirror the changed active flags to backup.
    public func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        // Resolve the scope and the previously-active host BEFORE the flip, so we can
        // mirror exactly the two records that change. Scoped to the current team
        // (single-active is per (account, team)).
        let team = await resolvedTeam(teamID)
        let account: String?
        if let stackUserID {
            account = stackUserID
        } else {
            account = try? await accountForMac(macDeviceID, teamID: team)
        }
        let previouslyActive = (account != nil)
            ? try? await inner.activeMac(stackUserID: account, teamID: team) : nil
        try await inner.setActive(macDeviceID: macDeviceID, stackUserID: account, teamID: team)
        // setActive flips the active flag for one host (and clears the previously-
        // active one in its scope) without going through `upsert`. Mirror ONLY those
        // two changed records to the DO so a "select host but don't connect, then
        // reinstall" sequence restores the right active host — WITHOUT a whole-
        // account upload, which would copy other-team hosts into the selected team's
        // DO (local rows carry no team id to filter by).
        guard let account else { return }
        lastSignedInAccount = account
        await uploadCurrentRecord(
            macDeviceID: macDeviceID,
            account: account,
            teamID: team,
            includesCustomizations: false
        )
        if let previouslyActive, previouslyActive.macDeviceID != macDeviceID {
            await uploadCurrentRecord(
                macDeviceID: previouslyActive.macDeviceID,
                account: account,
                teamID: team,
                includesCustomizations: false
            )
        }
    }

    /// Clear the active paired Mac locally and mirror the changed row to backup.
    public func clearActive(stackUserID: String?, teamID: String?) async throws {
        let team = await resolvedTeam(teamID)
        let previous = stackUserID != nil
            ? try? await inner.activeMac(stackUserID: stackUserID, teamID: team) : nil
        try await inner.clearActive(stackUserID: stackUserID, teamID: team)
        guard let stackUserID, let previous else { return }
        lastSignedInAccount = stackUserID
        await uploadCurrentRecord(
            macDeviceID: previous.macDeviceID,
            account: stackUserID,
            teamID: team,
            includesCustomizations: false
        )
    }

    /// Persist local customizations in one explicit owner scope, then mirror the
    /// complete scoped row to backup.
    public func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        let team = await resolvedTeam(teamID)
        try await inner.setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: team,
            now: now
        )
        let account: String?
        if let stackUserID {
            account = stackUserID
        } else {
            account = try? await accountForMac(macDeviceID, teamID: team)
        }
        guard let account else { return }
        lastSignedInAccount = account
        await uploadCurrentRecord(
            macDeviceID: macDeviceID,
            account: account,
            teamID: team,
            includesCustomizations: true
        )
    }

    /// Remove one paired Mac locally and tombstone it in backup when signed in.
    public func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        let team = await resolvedTeam(teamID)
        let account: String?
        if let stackUserID {
            account = stackUserID
        } else {
            account = try? await accountForMac(macDeviceID, teamID: team)
        }
        // Only mirror the delete while signed in; an anonymous removal has no
        // per-user backup to delete and would just fail auth and log noise.
        let backupAccount = account ?? lastSignedInAccount
        let scope: String?
        if let backupAccount {
            scope = await scopeKey(account: backupAccount, teamID: team)
        } else {
            scope = nil
        }
        if let scope {
            // Persist the delete intent before removing the only local row. If the
            // app dies or the network upload fails after the local delete, the next
            // read/restore still applies this tombstone and retries the backup
            // delete instead of restoring the stale live record from the server.
            // The catch below rolls this intent back if the local delete itself
            // fails, so the outbox never claims a row was forgotten locally when it
            // was not.
            await addPendingDelete(macDeviceID: macDeviceID, scope: scope)
        }
        let draining = cancelInFlightRestoresReturningTasks()
        for task in draining { _ = await task.value }
        do {
            try await inner.remove(macDeviceID: macDeviceID, stackUserID: account, teamID: team)
            if let scope, let backupAccount {
                await flushPendingDeletes(scope: scope, account: backupAccount, teamID: team)
            }
        } catch {
            if let scope {
                await clearPendingDelete(macDeviceID: macDeviceID, scope: scope)
            }
            throw error
        }
    }

    /// Clear local paired Macs without deleting the user's server backup.
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

    /// Cancel in-flight restore work so a sign-out/account switch cannot resume stale writes.
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
        restoreBoundary.invalidate()
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
        let scope = await scopeKey(account: account, teamID: team.isEmpty ? nil : team)
        let restoreTeam = team.isEmpty ? nil : team
        await applyPendingLocalDeletes(scope: scope, account: account, teamID: restoreTeam)
        _ = await flushPendingDeletes(scope: scope, account: account, teamID: restoreTeam)
        let task: Task<RestoreOutcome, Never>
        if let existing = inFlight[scope] {
            task = existing
        } else {
            let restore = PairedMacRestore(store: inner, backup: backup)
            let pendingDeletes = await pendingDeleteIDs(scope: scope)
            let boundaryGeneration = restoreBoundary.generation
            let created = Task {
                await restore.run(
                    accountID: account,
                    teamID: restoreTeam,
                    boundary: restoreBoundary,
                    boundaryGeneration: boundaryGeneration,
                    locallyDeletedMacDeviceIDs: pendingDeletes
                )
            }
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
        if outcome.completed {
            restoredScopes.insert(scope)
            await flushPendingDeletes(scope: scope, account: account, teamID: restoreTeam)
        }
    }

    // MARK: - Internals

    /// The team to scope an inner call to: an explicit `teamID` wins (e.g. a restore
    /// that knows its team), else the currently-selected team. (`??` can't take an
    /// async right-hand side, so this is a plain method.)
    private func resolvedTeam(_ teamID: String?) async -> String? {
        if let teamID { return teamID }
        return await teamIDProvider()
    }

    private func scopeKey(account: String, teamID: String?) async -> String {
        let clientScope = await backup.clientScope() ?? ""
        guard !clientScope.isEmpty else {
            return "\(account)\u{0}\(teamID ?? "")"
        }
        return "\(account)\u{0}\(teamID ?? "")\u{0}\(clientScope)"
    }

    /// Resolve the owning Stack account of a paired Mac, or nil if unknown. Reads
    /// across ALL teams (find-by-id) so a Mac is resolvable regardless of which team
    /// is selected.
    private func accountForMac(_ macDeviceID: String, teamID: String?) async throws -> String? {
        let all = try await inner.loadAll(stackUserID: nil, teamID: teamID)
        return all.first { $0.macDeviceID == macDeviceID }?.stackUserID
    }

    /// Build a backup record for a Mac from the local row. Callers choose whether
    /// that record is encoded with authoritative customization keys; routine
    /// route/active refreshes omit them so the worker preserves newer server state.
    /// Timestamps are ms since epoch (the backup wire format).
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

    /// Upload the current record for one Mac. `includesCustomizations` is true
    /// only for explicit rename/color/icon writes; other mirrors preserve the
    /// server's current customizations. Best-effort.
    @discardableResult
    private func uploadCurrentRecord(
        macDeviceID: String,
        account: String,
        teamID: String? = nil,
        includesCustomizations: Bool = false,
        allowTombstoneRevive: Bool = false
    ) async -> Bool {
        let team = await resolvedTeam(teamID)
        guard let mac = (try? await inner.loadAll(stackUserID: account, teamID: team))?
            .first(where: { $0.macDeviceID == macDeviceID }) else { return false }
        let record = Self.backupRecord(from: mac)
        let op: PairedMacBackupOp
        if allowTombstoneRevive {
            op = includesCustomizations
                ? .revive(record)
                : .revivePreservingCustomizations(record)
        } else if includesCustomizations {
            op = .upsert(record)
        } else {
            op = .upsertPreservingCustomizations(record)
        }
        return await backup.upload(ops: [op], teamID: team, expectedUserID: account)
    }

    /// Run the backup restore once per signed-in (account, team) scope this
    /// launch. Concurrent reads share one in-flight restore; only a SUCCESSFUL
    /// fetch is memoized, so a transient failure retries on the next read.
    private func restoreIfNeeded(_ stackUserID: String?) async {
        guard let account = stackUserID, !account.isEmpty else { return }
        lastSignedInAccount = account
        let team = (await teamIDProvider()) ?? ""
        let scope = await scopeKey(account: account, teamID: team.isEmpty ? nil : team)
        let restoreTeam = team.isEmpty ? nil : team
        await applyPendingLocalDeletes(scope: scope, account: account, teamID: restoreTeam)
        _ = await flushPendingDeletes(scope: scope, account: account, teamID: restoreTeam)
        if restoredScopes.contains(scope) { return }

        let task: Task<RestoreOutcome, Never>
        if let existing = inFlight[scope] {
            task = existing
        } else {
            let restore = PairedMacRestore(store: inner, backup: backup)
            let pendingDeletes = await pendingDeleteIDs(scope: scope)
            let boundaryGeneration = restoreBoundary.generation
            let created = Task {
                await restore.run(
                    accountID: account,
                    teamID: restoreTeam,
                    boundary: restoreBoundary,
                    boundaryGeneration: boundaryGeneration,
                    locallyDeletedMacDeviceIDs: pendingDeletes
                )
            }
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
        if outcome.completed {
            restoredScopes.insert(scope)
            await flushPendingDeletes(scope: scope, account: account, teamID: restoreTeam)
        }
    }

    private func pendingDeleteIDs(scope: String) async -> Set<String> {
        if let ids = pendingDeleteIDsByScope[scope] { return ids }
        let ids = await pendingDeleteStore.load(scope: scope)
        pendingDeleteIDsByScope[scope] = ids
        return ids
    }

    private func savePendingDeleteIDs(_ ids: Set<String>, scope: String) async {
        pendingDeleteIDsByScope[scope] = ids
        await pendingDeleteStore.save(ids, scope: scope)
    }

    private func addPendingDelete(macDeviceID: String, scope: String) async {
        let trimmed = macDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var ids = await pendingDeleteIDs(scope: scope)
        ids.insert(trimmed)
        await savePendingDeleteIDs(ids, scope: scope)
    }

    @discardableResult
    private func clearPendingDelete(macDeviceID: String, account: String, teamID: String?) async -> Bool {
        let scope = await scopeKey(account: account, teamID: teamID)
        return await clearPendingDelete(macDeviceID: macDeviceID, scope: scope)
    }

    @discardableResult
    private func clearPendingDelete(macDeviceID: String, scope: String) async -> Bool {
        var ids = await pendingDeleteIDs(scope: scope)
        guard ids.remove(macDeviceID) != nil else { return false }
        await savePendingDeleteIDs(ids, scope: scope)
        return true
    }

    private func applyPendingLocalDeletes(scope: String, account: String, teamID: String?) async {
        let ids = await pendingDeleteIDs(scope: scope)
        guard !ids.isEmpty else { return }
        for macDeviceID in ids {
            try? await inner.remove(macDeviceID: macDeviceID, stackUserID: account, teamID: teamID)
        }
    }

    @discardableResult
    private func flushPendingDeletes(scope: String, account: String, teamID: String?) async -> Set<String> {
        let ids = await pendingDeleteIDs(scope: scope)
        guard !ids.isEmpty else { return ids }
        let ops = ids.sorted().map { PairedMacBackupOp.delete(macDeviceID: $0) }
        guard await backup.upload(ops: ops, teamID: teamID, expectedUserID: account) else { return ids }
        await savePendingDeleteIDs([], scope: scope)
        return []
    }

}
