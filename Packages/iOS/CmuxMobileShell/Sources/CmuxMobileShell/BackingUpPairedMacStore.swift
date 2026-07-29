public import CMUXMobileCore
public import CmuxMobilePairedMac
public import Foundation

/// A ``MobilePairedMacStoring`` decorator that keeps the per-user Durable Object
/// backup in sync with the local store, and restores from it on sign-in. Wraps
/// the real ``MobilePairedMacStore`` at the composition root behind the
/// ``MobilePairedMacBackup`` flag, so EVERY paired-Mac mutation (route refresh,
/// pairing, rename, legacy delete, active switch) flows through one seam — no per-call-
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
    let inner: any MobilePairedMacStoring
    let backup: any PairedMacBackingUp
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
    var lastSignedInAccount: String?
    private let restoreBoundary: PairedMacRestoreBoundary
    private let pendingDeleteStore: any PairedMacPendingDeleteStoring
    /// Server-verified backup team per pairing (see ``PairedMacBackupTeamStoring``):
    /// where each record's backup actually lives, learned from the upload echo,
    /// so its delete tombstone can be routed there instead of re-resolving a
    /// nil team at delete time.
    private let backupTeamStore: any PairedMacBackupTeamStoring
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
        pendingDeleteStore: any PairedMacPendingDeleteStoring = InMemoryPairedMacPendingDeleteStore(),
        backupTeamStore: any PairedMacBackupTeamStoring = InMemoryPairedMacBackupTeamStore()
    ) {
        self.inner = inner
        self.backup = backup
        self.teamIDProvider = teamIDProvider
        self.restoreBoundary = restoreBoundary
        self.pendingDeleteStore = pendingDeleteStore
        self.backupTeamStore = backupTeamStore
    }

    /// Mapping key for one pairing's server-verified backup team. The ROW's
    /// own team is part of the key: the local store deliberately allows the
    /// same (account, device, tag) pairing to exist under several team scopes,
    /// so a key without the team would let team B's upload overwrite team A's
    /// destination and later route A's tombstone into B's backup.
    private func backupTeamKey(account: String, rowTeamID: String?, pairingID: String) -> String {
        "\(account)\u{0}\(rowTeamID ?? "")\u{0}\(pairingID)"
    }

    /// Persist the server-verified backup team for a batch of pairings (the
    /// restore snapshot's echo). `rowTeamID` is the team the restored rows are
    /// stamped with (the restore scope's team).
    private func recordResolvedBackupTeams(
        _ pairingIDs: [String],
        rowTeamID: String?,
        teamID: String,
        account: String
    ) async {
        for pairingID in pairingIDs {
            await backupTeamStore.save(
                teamID,
                key: backupTeamKey(account: account, rowTeamID: rowTeamID, pairingID: pairingID)
            )
        }
    }

    /// Upsert a paired Mac locally, then mirror the changed backup records.
    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String? = nil,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
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
            let existing = (try? await inner.loadAll(stackUserID: account, teamID: team)) ?? []
            previouslyActive = existing.first { $0.isActive }
        } else {
            previouslyActive = nil
        }
        try await inner.upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
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
        _ = await clearPendingDelete(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            account: account,
            teamID: team
        )
        // Every server tombstone is a legacy-delete artifact. Always let a
        // current local row revive it so obsolete deletes cannot block backup.
        await uploadCurrentRecord(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            account: account,
            teamID: team,
            includesCustomizations: false,
            allowTombstoneRevive: true
        )
        // `markActive` clears the active flag of the account's previously-active
        // host locally; mirror THAT one record too so the backup keeps its
        // single-active invariant — without re-uploading the whole account, which
        // would copy other-team hosts into the selected team's DO (the local rows
        // carry no team id to filter by). See `setActive`.
        if markActive,
           let previouslyActive,
           previouslyActive.id != MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
           ) {
            await uploadCurrentRecord(
                macDeviceID: previouslyActive.macDeviceID,
                instanceTag: previouslyActive.instanceTag,
                account: account,
                teamID: team,
                includesCustomizations: false,
                instanceAuthority: .preserve
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
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let team = await teamIDProvider()
        let target = try? await macFor(
            macDeviceID,
            instanceTag: nil,
            stackUserID: nil,
            teamID: team,
            requiresExactInstanceTag: false
        )
        try await setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: target?.stackUserID,
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
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let team = await resolvedTeam(teamID)
        let target = try? await macFor(
            macDeviceID,
            instanceTag: nil,
            stackUserID: stackUserID,
            teamID: team,
            requiresExactInstanceTag: false
        )
        try await setActive(
            macDeviceID: macDeviceID,
            instanceTag: target?.instanceTag,
            stackUserID: stackUserID,
            teamID: team
        )
    }

    /// Mark one exact tagged pairing active and mirror its active state.
    public func setActive(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        // Resolve the scope and the previously-active host BEFORE the flip, so we can
        // mirror exactly the two records that change. Scoped to the current team
        // (single-active is per (account, team)).
        let team = await resolvedTeam(teamID)
        let account: String?
        if let stackUserID {
            account = stackUserID
        } else {
            account = try? await accountForMac(
                macDeviceID,
                instanceTag: instanceTag,
                teamID: team
            )
        }
        let previouslyActive = (account != nil)
            ? try? await inner.activeMac(stackUserID: account, teamID: team) : nil
        try await inner.setActive(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: account,
            teamID: team
        )
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
            instanceTag: instanceTag,
            account: account,
            teamID: team,
            includesCustomizations: false,
            instanceAuthority: .preserve
        )
        if let previouslyActive,
           previouslyActive.id != MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
           ) {
            await uploadCurrentRecord(
                macDeviceID: previouslyActive.macDeviceID,
                instanceTag: previouslyActive.instanceTag,
                account: account,
                teamID: team,
                includesCustomizations: false,
                instanceAuthority: .preserve
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
            instanceTag: previous.instanceTag,
            account: stackUserID,
            teamID: team,
            includesCustomizations: false,
            instanceAuthority: .preserve
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
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let team = await resolvedTeam(teamID)
        let target = try? await macFor(
            macDeviceID,
            instanceTag: nil,
            stackUserID: stackUserID,
            teamID: team,
            requiresExactInstanceTag: false
        )
        try await setCustomization(
            macDeviceID: macDeviceID,
            instanceTag: target?.instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: team,
            now: now
        )
    }

    /// Persist customizations for one exact tagged pairing.
    public func setCustomization(
        macDeviceID: String,
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let team = await resolvedTeam(teamID)
        try await inner.setCustomization(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
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
            account = try? await accountForMac(
                macDeviceID,
                instanceTag: instanceTag,
                teamID: team
            )
        }
        guard let account else { return }
        lastSignedInAccount = account
        await uploadCurrentRecord(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            account: account,
            teamID: team,
            includesCustomizations: true,
            instanceAuthority: .preserve
        )
    }

    /// Remove one paired Mac locally and tombstone it in backup when signed in.
    public func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let team = await resolvedTeam(teamID)
        let target = try? await macFor(
            macDeviceID,
            instanceTag: nil,
            stackUserID: stackUserID,
            teamID: team,
            requiresExactInstanceTag: false
        )
        try await remove(
            macDeviceID: macDeviceID,
            instanceTag: target?.instanceTag,
            stackUserID: stackUserID,
            teamID: team
        )
    }

    /// Remove one exact tagged pairing locally and mirror the delete.
    public func remove(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        let team = await resolvedTeam(teamID)
        try await removeMirroring(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            team: team,
            exactScope: false
        )
    }

    /// Remove one exact tagged pairing in the EXACT captured team scope and
    /// mirror the delete.
    ///
    /// Identical to ``remove(macDeviceID:instanceTag:stackUserID:teamID:)``
    /// except a nil (team-less) `teamID` is NOT resolved to the currently-
    /// selected team. The forget-hidden-computer path captures its scope before
    /// an async revoke; if the user switches teams during that await, resolving
    /// nil to the live team here would tombstone the delete under, and remove
    /// the local row of, the newly-selected team instead of the team-less
    /// pairing this call targets. Delegates to `inner.removeExactScope` so the
    /// team-scoping decorator below also honors the captured scope.
    public func removeExactScope(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        try await removeMirroring(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            team: teamID,
            exactScope: true
        )
    }

    /// Shared local-delete + backup-mirror body for both `remove` and
    /// `removeExactScope`. `team` is already resolved by the caller (the live
    /// selected team for `remove`, the captured scope verbatim for
    /// `removeExactScope`) and scopes the LOCAL row delete; the backup
    /// tombstone routes to the row's verified DESTINATION (see the outbox
    /// section below). `exactScope` selects the matching inner delete so a
    /// team-less captured scope is preserved all the way down.
    private func removeMirroring(
        macDeviceID rawMacDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        team: String?,
        exactScope: Bool
    ) async throws {
        let macDeviceID = cmxCanonicalDeviceID(rawMacDeviceID)
        let account: String?
        if let stackUserID {
            account = stackUserID
        } else {
            account = try? await accountForMac(
                macDeviceID,
                instanceTag: instanceTag,
                teamID: team
            )
        }
        // Only mirror the delete while signed in; an anonymous removal has no
        // per-user backup to delete and would just fail auth and log noise.
        let backupAccount = account ?? lastSignedInAccount
        let planned: PlannedTombstone?
        if let backupAccount {
            // Persist the delete intent before removing the only local row. If the
            // app dies or the network upload fails after the local delete, the next
            // read/restore still applies this tombstone and retries the backup
            // delete instead of restoring the stale live record from the server.
            // The catch below rolls this intent back if the local delete itself
            // fails, so the outbox never claims a row was deleted locally when it
            // was not.
            let plan = await planTombstone(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                rowTeamID: team,
                account: backupAccount
            )
            await addPendingDelete(plan)
            planned = plan
        } else {
            planned = nil
        }
        let draining = cancelInFlightRestoresReturningTasks()
        for task in draining { _ = await task.value }
        do {
            if exactScope {
                try await inner.removeExactScope(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag,
                    stackUserID: account,
                    teamID: team
                )
            } else {
                try await inner.remove(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag,
                    stackUserID: account,
                    teamID: team
                )
            }
            if let planned {
                await flushPendingDeletes(
                    scope: planned.outboxScope,
                    account: planned.account,
                    teamID: planned.destinationTeamID
                )
            }
        } catch {
            if let planned {
                await clearPendingDelete(planned)
            }
            throw error
        }
    }

    /// Batch exact-scope removal: every row's local delete and outbox write
    /// happens first, then the accumulated tombstones flush ONCE per backup
    /// destination. The per-row `removeExactScope` flushes after each delete,
    /// so a wildcard forget covering many tagged/teamed rows would otherwise
    /// issue one sequential backup request per row — with failures each
    /// consuming a full request timeout — after the broker revoke loop already
    /// ran. Rows that fail their local delete have their intents rolled back
    /// and the first error is rethrown after every row was attempted and the
    /// successful rows' tombstones were flushed.
    public func removeExactScopes(_ scopes: [MobilePairedMacExactScope]) async throws {
        guard !scopes.isEmpty else { return }
        let draining = cancelInFlightRestoresReturningTasks()
        for task in draining { _ = await task.value }
        var flushTargets: [String: (account: String, destination: String?)] = [:]
        var firstError: (any Error)?
        for scope in scopes {
            let macDeviceID = cmxCanonicalDeviceID(scope.macDeviceID)
            let account: String?
            if let stackUserID = scope.stackUserID {
                account = stackUserID
            } else {
                account = try? await accountForMac(
                    macDeviceID,
                    instanceTag: scope.instanceTag,
                    teamID: scope.teamID
                )
            }
            let backupAccount = account ?? lastSignedInAccount
            let planned: PlannedTombstone?
            if let backupAccount {
                let plan = await planTombstone(
                    macDeviceID: macDeviceID,
                    instanceTag: scope.instanceTag,
                    rowTeamID: scope.teamID,
                    account: backupAccount
                )
                await addPendingDelete(plan)
                planned = plan
            } else {
                planned = nil
            }
            do {
                try await inner.removeExactScope(
                    macDeviceID: macDeviceID,
                    instanceTag: scope.instanceTag,
                    stackUserID: account,
                    teamID: scope.teamID
                )
                if let planned {
                    flushTargets[planned.outboxScope] = (
                        account: planned.account,
                        destination: planned.destinationTeamID
                    )
                }
            } catch {
                if let planned {
                    await clearPendingDelete(planned)
                }
                if firstError == nil { firstError = error }
            }
        }
        for (outboxScope, target) in flushTargets {
            await flushPendingDeletes(
                scope: outboxScope,
                account: target.account,
                teamID: target.destination
            )
        }
        if let firstError { throw firstError }
    }

    /// Cross-team enumeration forwards straight to the local rail. No restore
    /// is triggered: this read targets deletions during a forget, and kicking
    /// off a backup fetch there would race the very rows being removed.
    public func loadAllInstances(
        macDeviceID: String,
        stackUserID: String?
    ) async throws -> [MobilePairedMac] {
        try await inner.loadAllInstances(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID
        )
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
        let scope = await nonoptionalScopeKey(account: account, teamID: team.isEmpty ? nil : team)
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
            let restoreBoundary = restoreBoundary
            let created = Task {
                await restore.run(
                    accountID: account,
                    teamID: restoreTeam,
                    boundary: restoreBoundary,
                    boundaryGeneration: boundaryGeneration,
                    locallyDeletedMacDeviceIDs: pendingDeletes,
                    // Persist where the server SAID this snapshot's records live,
                    // so a restored row forgotten later (the reinstall case, when
                    // no upload ever recorded a mapping) still routes its delete
                    // tombstone to the right team's backup.
                    onResolvedBackupTeam: { [weak self] pairingIDs, resolvedTeamID in
                        await self?.recordResolvedBackupTeams(
                            pairingIDs,
                            rowTeamID: restoreTeam,
                            teamID: resolvedTeamID,
                            account: account
                        )
                    }
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
    func resolvedTeam(_ teamID: String?) async -> String? {
        if let teamID { return teamID }
        return await teamIDProvider()
    }

    /// Resolve the owning Stack account of a paired Mac, or nil if unknown. Reads
    /// across ALL teams (find-by-id) so a Mac is resolvable regardless of which team
    /// is selected.
    private func accountForMac(
        _ macDeviceID: String,
        instanceTag: String?,
        teamID: String?
    ) async throws -> String? {
        try await macFor(
            macDeviceID,
            instanceTag: instanceTag,
            stackUserID: nil,
            teamID: teamID,
            requiresExactInstanceTag: true
        )?.stackUserID
    }

    private func macFor(
        _ macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        requiresExactInstanceTag: Bool
    ) async throws -> MobilePairedMac? {
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        return try await inner.loadAll(stackUserID: stackUserID, teamID: teamID).first {
            cmxCanonicalDeviceID($0.macDeviceID) == macDeviceID
                && (!requiresExactInstanceTag || $0.instanceTag == instanceTag)
        }
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
            customIcon: mac.customIcon,
            instanceTag: mac.instanceTag
        )
    }

    /// Upload the current record for one Mac. `includesCustomizations` is true
    /// only for explicit rename/color/icon writes; other mirrors preserve the
    /// server's current customizations. Best-effort.
    @discardableResult
    func uploadCurrentRecord(
        macDeviceID: String,
        instanceTag: String? = nil,
        account: String,
        teamID: String? = nil,
        includesCustomizations: Bool = false,
        allowTombstoneRevive: Bool = false,
        instanceAuthority: PairedMacBackupInstanceAuthorityWriteMode = .authoritative
    ) async -> Bool {
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let team = await resolvedTeam(teamID)
        guard let mac = (try? await inner.loadAll(stackUserID: account, teamID: team))?
            .first(where: {
                cmxCanonicalDeviceID($0.macDeviceID) == macDeviceID
                    && $0.instanceTag == instanceTag
            }) else { return false }
        let record = Self.backupRecord(from: mac)
        let op: PairedMacBackupOp
        if allowTombstoneRevive {
            op = includesCustomizations
                ? .revive(record, instanceAuthority: instanceAuthority)
                : .revivePreservingCustomizations(
                    record,
                    instanceAuthority: instanceAuthority
                )
        } else if includesCustomizations {
            op = .upsert(record, instanceAuthority: instanceAuthority)
        } else {
            op = .upsertPreservingCustomizations(
                record,
                instanceAuthority: instanceAuthority
            )
        }
        let outcome = await backup.uploadReportingResolvedTeam(
            ops: [op],
            teamID: team,
            expectedUserID: account
        )
        // Remember where the server SAID it stored this record. A nil-team
        // upload is resolved server-side, and that resolution can drift by the
        // time the record is forgotten; the persisted echo lets the delete
        // tombstone route to the backup the record actually lives in.
        if outcome.succeeded, let resolvedTeamID = outcome.resolvedTeamID {
            await backupTeamStore.save(
                resolvedTeamID,
                key: backupTeamKey(
                    account: account,
                    rowTeamID: team,
                    pairingID: MobilePairedMac.pairingID(
                        macDeviceID: macDeviceID,
                        instanceTag: instanceTag
                    )
                )
            )
        }
        return outcome.succeeded
    }

    /// Run the backup restore once per signed-in (account, team) scope this
    /// launch. Concurrent reads share one in-flight restore; only a SUCCESSFUL
    /// fetch is memoized, so a transient failure retries on the next read.
    private func restoreIfNeeded(_ stackUserID: String?) async {
        guard let account = stackUserID, !account.isEmpty else { return }
        lastSignedInAccount = account
        let team = (await teamIDProvider()) ?? ""
        let scope = await nonoptionalScopeKey(account: account, teamID: team.isEmpty ? nil : team)
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
            let restoreBoundary = restoreBoundary
            let created = Task {
                await restore.run(
                    accountID: account,
                    teamID: restoreTeam,
                    boundary: restoreBoundary,
                    boundaryGeneration: boundaryGeneration,
                    locallyDeletedMacDeviceIDs: pendingDeletes,
                    // Persist where the server SAID this snapshot's records live,
                    // so a restored row forgotten later (the reinstall case, when
                    // no upload ever recorded a mapping) still routes its delete
                    // tombstone to the right team's backup.
                    onResolvedBackupTeam: { [weak self] pairingIDs, resolvedTeamID in
                        await self?.recordResolvedBackupTeams(
                            pairingIDs,
                            rowTeamID: restoreTeam,
                            teamID: resolvedTeamID,
                            account: account
                        )
                    }
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

    // MARK: - Pending delete outbox
    //
    // Records live under the scope key of their backup DESTINATION (the team
    // whose Durable Object holds the record), not the row's local scope: a
    // restore of the destination scope must both SEE the intent (so its
    // suppression list keeps the deleted record from resurrecting while the
    // upload is still pending) and retry the flush. Each record additionally
    // encodes the row's LOCAL team so the local replay can delete the exact
    // row regardless of where the backup lives. A team-less row with no
    // verified destination mapping is PARKED under the account's nil-team
    // scope and never uploaded with a guessed destination — the server would
    // re-resolve a nil team from its CURRENT account state, which can differ
    // from where the record was stored and destroy an unrelated same-pairing
    // record in another team. Parked intents flush once a restore's echo
    // recovers the verified mapping. Residual: while parked, a restore of a
    // DIFFERENT team's scope cannot see the intent and may resurrect the
    // record as that team's row; re-forgetting that row then routes exactly
    // (its scope is concrete), which is recoverable — unlike a misrouted
    // destructive delete.

    /// One pending tombstone: the pairing it deletes and the LOCAL team scope
    /// of the row it deleted (needed for exact local replay).
    private struct PendingDeleteRecord: Hashable {
        let pairingID: String
        let localTeamID: String?

        /// `pairingID` alone (a legacy record whose local team equals its
        /// scope's team), or `pairingID<RS>localTeam` with "" = team-less.
        static let separator: Character = "\u{1E}"

        func encoded() -> String {
            "\(pairingID)\(Self.separator)\(localTeamID ?? "")"
        }

        /// Decode a stored record. A legacy record (no separator) predates the
        /// destination-keyed outbox, where local scope == the record's scope,
        /// so its local team is the scope's own team.
        init(decoding raw: String, scopeTeamID: String?) {
            let parts = raw.split(
                separator: Self.separator,
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let identity = MobilePairedMac.pairingIdentity(from: String(parts[0]))
            pairingID = MobilePairedMac.pairingID(
                macDeviceID: identity.macDeviceID,
                instanceTag: identity.instanceTag
            )
            if parts.count == 2 {
                let team = String(parts[1])
                localTeamID = team.isEmpty ? nil : team
            } else {
                localTeamID = scopeTeamID
            }
        }

        init(pairingID: String, localTeamID: String?) {
            self.pairingID = pairingID
            self.localTeamID = localTeamID
        }
    }

    /// Where one row's tombstone must go, and the outbox record that carries it.
    private struct PlannedTombstone {
        let record: PendingDeleteRecord
        /// The verified backup destination team, or nil when it is unknown
        /// (a team-less row with no persisted echo) and the intent is parked.
        let destinationTeamID: String?
        let outboxScope: String
        let account: String
    }

    /// Resolve a row's tombstone destination: the persisted upload/restore echo
    /// when one exists, else the row's OWN concrete team (symmetric with the
    /// upload, which targeted that team explicitly — not a guess). A team-less
    /// row with no echo has an unknowable destination and parks.
    private func planTombstone(
        macDeviceID: String,
        instanceTag: String?,
        rowTeamID: String?,
        account: String
    ) async -> PlannedTombstone {
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        let mapped = await backupTeamStore.load(
            key: backupTeamKey(account: account, rowTeamID: rowTeamID, pairingID: pairingID)
        )
        let destination = mapped ?? rowTeamID
        return PlannedTombstone(
            record: PendingDeleteRecord(pairingID: pairingID, localTeamID: rowTeamID),
            destinationTeamID: destination,
            outboxScope: await nonoptionalScopeKey(account: account, teamID: destination),
            account: account
        )
    }

    private func pendingRecords(scope: String) async -> Set<String> {
        if let ids = pendingDeleteIDsByScope[scope] { return ids }
        let stored = await pendingDeleteStore.load(scope: scope)
        pendingDeleteIDsByScope[scope] = stored
        return stored
    }

    private func savePendingRecords(_ records: Set<String>, scope: String) async {
        pendingDeleteIDsByScope[scope] = records
        await pendingDeleteStore.save(records, scope: scope)
    }

    /// The pairing ids pending in one scope, for the restore's resurrect
    /// suppression list.
    private func pendingDeleteIDs(scope: String) async -> Set<String> {
        let scopeTeam = teamID(fromScopeKey: scope)
        return Set(await pendingRecords(scope: scope).map {
            PendingDeleteRecord(decoding: $0, scopeTeamID: scopeTeam).pairingID
        })
    }

    /// The team component of a scope key (`account\0team[\0clientScope]`).
    private func teamID(fromScopeKey scope: String) -> String? {
        let parts = scope.split(separator: "\u{0}", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    private func addPendingDelete(_ planned: PlannedTombstone) async {
        var records = await pendingRecords(scope: planned.outboxScope)
        records.insert(planned.record.encoded())
        await savePendingRecords(records, scope: planned.outboxScope)
    }

    private func clearPendingDelete(_ planned: PlannedTombstone) async {
        var records = await pendingRecords(scope: planned.outboxScope)
        guard records.remove(planned.record.encoded()) != nil else { return }
        await savePendingRecords(records, scope: planned.outboxScope)
    }

    /// Drop any pending tombstone for a pairing that was just re-added
    /// (revive): the intent could sit under its mapped destination scope, its
    /// own team's scope, or the parked nil-team scope, in either encoding.
    @discardableResult
    func clearPendingDelete(
        macDeviceID: String,
        instanceTag: String?,
        account: String,
        teamID: String?
    ) async -> Bool {
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        let mapped = await backupTeamStore.load(
            key: backupTeamKey(account: account, rowTeamID: teamID, pairingID: pairingID)
        )
        var candidateTeams: [String?] = [teamID, nil]
        if let mapped { candidateTeams.append(mapped) }
        var cleared = false
        for team in candidateTeams {
            let scope = await nonoptionalScopeKey(account: account, teamID: team)
            var records = await pendingRecords(scope: scope)
            let before = records.count
            records = records.filter {
                PendingDeleteRecord(
                    decoding: $0,
                    scopeTeamID: team
                ).pairingID != pairingID
            }
            if records.count != before {
                await savePendingRecords(records, scope: scope)
                cleared = true
            }
        }
        return cleared
    }

    /// Re-apply pending tombstones locally before a restore for their scope.
    ///
    /// Each record encodes the LOCAL team of the row it deleted, so the replay
    /// deletes exactly that row via `removeExactScope` — never re-resolving
    /// visibility through the broad `remove`, which could target a surviving
    /// unrelated alias of the same device in the common already-deleted case.
    private func applyPendingLocalDeletes(scope: String, account: String, teamID: String?) async {
        let records = await pendingRecords(scope: scope)
        guard !records.isEmpty else { return }
        for raw in records {
            let record = PendingDeleteRecord(decoding: raw, scopeTeamID: teamID)
            let identity = MobilePairedMac.pairingIdentity(from: record.pairingID)
            try? await inner.removeExactScope(
                macDeviceID: identity.macDeviceID,
                instanceTag: identity.instanceTag,
                stackUserID: account,
                teamID: record.localTeamID
            )
        }
    }

    /// Flush one scope's pending tombstones.
    ///
    /// A scope with a CONCRETE team IS the verified destination: all of its
    /// records go out in ONE request to that team. The nil-team scope holds
    /// PARKED intents whose destination was unknown when they were written;
    /// each is re-checked against the mapping store (restores' echoes recover
    /// mappings over time), and any now-verified intent MIGRATES to its
    /// destination scope — so suppression there sees it even if its upload
    /// fails — and flushes with it. Unverified intents stay parked; a nil
    /// destination is never guessed. Returns the records still pending.
    @discardableResult
    private func flushPendingDeletes(scope: String, account: String, teamID: String?) async -> Set<String> {
        var records = await pendingRecords(scope: scope)
        guard !records.isEmpty else { return records }
        if let teamID {
            let decoded = records.map {
                PendingDeleteRecord(decoding: $0, scopeTeamID: teamID)
            }
            let ops = decoded
                .sorted { $0.pairingID < $1.pairingID }
                .map { record -> PairedMacBackupOp in
                    let identity = MobilePairedMac.pairingIdentity(from: record.pairingID)
                    if let instanceTag = identity.instanceTag {
                        return .deleteInstance(
                            macDeviceID: identity.macDeviceID,
                            instanceTag: instanceTag
                        )
                    }
                    return .delete(macDeviceID: identity.macDeviceID)
                }
            guard await backup.upload(
                ops: ops,
                teamID: teamID,
                expectedUserID: account
            ) else { return records }
            for record in decoded {
                await backupTeamStore.remove(
                    key: backupTeamKey(
                        account: account,
                        rowTeamID: record.localTeamID,
                        pairingID: record.pairingID
                    )
                )
            }
            await savePendingRecords([], scope: scope)
            return []
        }
        // The parked nil-team scope: migrate now-verified intents to their
        // destination scopes and flush those; keep the rest parked.
        var migratedScopes: Set<String> = []
        var stillParked = records
        for raw in records {
            let record = PendingDeleteRecord(decoding: raw, scopeTeamID: nil)
            guard let destination = await backupTeamStore.load(
                key: backupTeamKey(
                    account: account,
                    rowTeamID: record.localTeamID,
                    pairingID: record.pairingID
                )
            ) else { continue }
            let destinationScope = await nonoptionalScopeKey(account: account, teamID: destination)
            var destinationRecords = await pendingRecords(scope: destinationScope)
            destinationRecords.insert(record.encoded())
            await savePendingRecords(destinationRecords, scope: destinationScope)
            stillParked.remove(raw)
            migratedScopes.insert(destination)
        }
        if stillParked.count != records.count {
            await savePendingRecords(stillParked, scope: scope)
        }
        for destination in migratedScopes {
            let destinationScope = await nonoptionalScopeKey(account: account, teamID: destination)
            _ = await flushPendingDeletes(
                scope: destinationScope,
                account: account,
                teamID: destination
            )
        }
        records = stillParked
        return records
    }

}
