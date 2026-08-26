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

    /// Injected clock read for the parked-tombstone eviction stamps.
    private let now: @Sendable () -> Date
    private let diagnosticLog: DiagnosticLog?

    /// Upper bound on the parked account-wide tombstone set (see
    /// ``removeExactScopes(_:)``); mirrors the discovery snapshot's 256-binding
    /// wire cap, far above any realistic count of forgotten pairings.
    static let parkedTombstoneCap = 256

    /// Wrap a local paired-Mac store with a backup transport.
    public init(
        inner: any MobilePairedMacStoring,
        backup: any PairedMacBackingUp,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil },
        restoreBoundary: PairedMacRestoreBoundary = PairedMacRestoreBoundary(),
        pendingDeleteStore: any PairedMacPendingDeleteStoring = InMemoryPairedMacPendingDeleteStore(),
        backupTeamStore: any PairedMacBackupTeamStoring = InMemoryPairedMacBackupTeamStore(),
        now: @escaping @Sendable () -> Date = { Date() },
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.inner = inner
        self.backup = backup
        self.teamIDProvider = teamIDProvider
        self.restoreBoundary = restoreBoundary
        self.pendingDeleteStore = pendingDeleteStore
        self.backupTeamStore = backupTeamStore
        self.now = now
        self.diagnosticLog = diagnosticLog
    }

    /// Mapping key for one pairing's server-verified backup team. The ROW's
    /// own team is part of the key: the local store deliberately allows the
    /// same (account, device, tag) pairing to exist under several team scopes,
    /// so a key without the team would let team B's upload overwrite team A's
    /// destination and later route A's tombstone into B's backup.
    private func backupTeamKey(account: String, rowTeamID: String?, pairingID: String) -> String {
        "\(account)\u{0}\(rowTeamID ?? "")\u{0}\(pairingID)"
    }

    /// Persist the server-verified backup team for a restore snapshot's
    /// echoes. Each mapping is keyed by the RETAINED local row's own team when
    /// one survived the merge (LWW can keep a newer team-less row without
    /// re-stamping it into the restore's team, and the later forget looks the
    /// mapping up under the row's actual scope); a record with no local row
    /// maps under the restore scope's team, covering the reinstall case.
    private func recordResolvedBackupTeams(
        _ echoes: [PairedMacRestoreEcho],
        restoreTeam: String?,
        teamID: String,
        account: String
    ) async {
        // ONE persistence pass for the whole snapshot: the durable store
        // rewrites its full state per save, so per-record saves would do
        // quadratic work while the user-visible paired-Mac load awaits the
        // restore.
        await backupTeamStore.saveAll(echoes.map { echo in
            let rowTeam = echo.hasRetainedLocalRow ? echo.retainedRowTeamID : restoreTeam
            return PairedMacBackupTeamMapping(
                key: backupTeamKey(account: account, rowTeamID: rowTeam, pairingID: echo.pairingID),
                teamID: teamID
            )
        })
        await resolveParkedTombstones(
            matching: echoes,
            verifiedTeamID: teamID,
            account: account
        )
    }

    /// A verified team's snapshot is a destination ECHO for PARKED tombstones:
    /// a parked intent's pairing appearing in that snapshot proves that team's
    /// backup holds it, so a delete for each matched record goes to that team
    /// directly. A tag-less parked intent is a device-wide (wildcard) forget
    /// and matches EVERY tag of its device — the snapshot supplies the concrete
    /// tags the intent could not know. Intents are RETAINED after sending: any
    /// number of OTHER teams' backups may still hold the pairing (backups are
    /// per-team Durable Objects, and other devices upload under their own
    /// teams), so each intent keeps suppressing and deleting until the pairing
    /// is revived by a re-pair. The upload is best-effort — a failure leaves
    /// the intent to retry on that team's next restore, and suppression hides
    /// the record meanwhile.
    private func resolveParkedTombstones(
        matching echoes: [PairedMacRestoreEcho],
        verifiedTeamID: String,
        account: String
    ) async {
        let parkedScope = await nonoptionalScopeKey(account: account, teamID: nil)
        var parked = await pendingRecords(scope: parkedScope)
        guard !parked.isEmpty else { return }
        struct ParkedIntent {
            let raw: String
            let pairingID: String
            let deviceID: String
            let isDeviceWide: Bool
            let stampMs: Double
        }
        func decodeIntents(_ raws: Set<String>) -> [ParkedIntent] {
            raws.map { raw in
                let record = PendingDeleteRecord(decoding: raw, scopeTeamID: nil)
                let identity = MobilePairedMac.pairingIdentity(from: record.pairingID)
                return ParkedIntent(
                    raw: raw,
                    pairingID: record.pairingID,
                    deviceID: cmxCanonicalDeviceID(identity.macDeviceID),
                    isDeviceWide: identity.instanceTag == nil,
                    stampMs: record.stampMs
                )
            }
        }
        func covers(_ intent: ParkedIntent, _ echo: PairedMacRestoreEcho) -> Bool {
            if intent.pairingID == echo.pairingID { return true }
            guard intent.isDeviceWide else { return false }
            let identity = MobilePairedMac.pairingIdentity(from: echo.pairingID)
            return cmxCanonicalDeviceID(identity.macDeviceID) == intent.deviceID
        }
        // Retirement: a record the SERVER wrote after the intent was parked is
        // a REVIVAL — another device re-paired the Mac — not a stale copy. The
        // intent retires instead of deleting it; without this, the forgetting
        // phone would delete the revival on every restore forever. The signal
        // is the server-authored write time (client-authored createdAt is
        // preserved across re-pairs on other phones), compared through the
        // shared skew-margined rule. Unstamped legacy intents have no boundary
        // and keep the old delete behavior.
        var retiredRaws: Set<String> = []
        for intent in decodeIntents(parked) where intent.stampMs > 0 {
            let boundary = PairedMacRestoreSuppression(
                pairingID: intent.pairingID,
                stampMs: intent.stampMs
            )
            // Retirement is EXACT: only the intent's own pairing reviving
            // retires it. A device-wide intent covers every tag of its device
            // for suppression and deletion, but one tagged instance coming
            // back does not prove the OTHER tags' stale records (possibly in
            // other teams' backups) were re-added — per-record revival
            // classification already lets the revived tag through everywhere,
            // so keeping the intent costs the revival nothing.
            let revived = echoes.contains { echo in
                echo.pairingID == intent.pairingID
                    && boundary.treatsAsRevived(serverUpdatedAtMs: echo.serverUpdatedAtMs)
            }
            if revived { retiredRaws.insert(intent.raw) }
        }
        if !retiredRaws.isEmpty {
            parked.subtract(retiredRaws)
            await savePendingRecords(parked, scope: parkedScope)
            guard !parked.isEmpty else { return }
        }
        var parkedExact: Set<String> = []
        var parkedDevices: Set<String> = []
        for intent in decodeIntents(parked) {
            if intent.isDeviceWide {
                parkedDevices.insert(intent.deviceID)
            }
            parkedExact.insert(intent.pairingID)
        }
        var ops: [PairedMacBackupOp] = []
        var sentPairingIDs: [String] = []
        let survivingIntents = decodeIntents(parked)
        for echo in echoes.sorted(by: { $0.pairingID < $1.pairingID }) {
            let pairingID = echo.pairingID
            let identity = MobilePairedMac.pairingIdentity(from: pairingID)
            let device = cmxCanonicalDeviceID(identity.macDeviceID)
            guard parkedExact.contains(pairingID) || parkedDevices.contains(device) else {
                continue
            }
            // A record every covering intent classifies as REVIVED is spared:
            // the covering device-wide intent survives for OTHER tags, but
            // this record was re-added after the forget.
            let coveringIntents = survivingIntents.filter { covers($0, echo) }
            let revivedForAll = !coveringIntents.isEmpty && coveringIntents.allSatisfy { intent in
                PairedMacRestoreSuppression(
                    pairingID: intent.pairingID,
                    stampMs: intent.stampMs
                ).treatsAsRevived(serverUpdatedAtMs: echo.serverUpdatedAtMs)
            }
            if revivedForAll { continue }
            guard !sentPairingIDs.contains(pairingID) else { continue }
            if let instanceTag = identity.instanceTag {
                ops.append(.deleteInstance(
                    macDeviceID: identity.macDeviceID,
                    instanceTag: instanceTag
                ))
            } else {
                ops.append(.delete(macDeviceID: identity.macDeviceID))
            }
            sentPairingIDs.append(pairingID)
        }
        guard !ops.isEmpty else { return }
        guard await backup.upload(ops: ops, teamID: verifiedTeamID, expectedUserID: account) else {
            return
        }
        // Reentrancy fence: this actor suspended across the upload, so a
        // re-pair may have CLEARED one of the sent intents and uploaded a
        // revive — and this older delete then landed after it, wiping the
        // just-revived record. For each sent pairing no longer covered by a
        // parked intent, re-upload its current local row as a revive; when no
        // local row exists the pairing was not revived and the delete stands.
        let remaining = await pendingRecords(scope: parkedScope)
        var remainingExact: Set<String> = []
        var remainingDevices: Set<String> = []
        for raw in remaining {
            let record = PendingDeleteRecord(decoding: raw, scopeTeamID: nil)
            let identity = MobilePairedMac.pairingIdentity(from: record.pairingID)
            if identity.instanceTag == nil {
                remainingDevices.insert(cmxCanonicalDeviceID(identity.macDeviceID))
            }
            remainingExact.insert(record.pairingID)
        }
        for pairingID in sentPairingIDs {
            let identity = MobilePairedMac.pairingIdentity(from: pairingID)
            let device = cmxCanonicalDeviceID(identity.macDeviceID)
            guard !remainingExact.contains(pairingID), !remainingDevices.contains(device) else {
                continue
            }
            _ = await uploadCurrentRecord(
                macDeviceID: identity.macDeviceID,
                instanceTag: identity.instanceTag,
                account: account,
                teamID: verifiedTeamID,
                allowTombstoneRevive: true
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
        guard let target else { return }
        try await setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: target.stackUserID,
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
        guard let target else { return }
        try await setActive(
            macDeviceID: macDeviceID,
            instanceTag: target.instanceTag,
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
        guard let target else { return }
        try await setCustomization(
            macDeviceID: macDeviceID,
            instanceTag: target.instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: team,
            now: now
        )
    }

    /// Device-local per-Computer connection method: forwarded verbatim and
    /// deliberately NOT mirrored into the account backup.
    public func setConnectionMethod(
        macDeviceID: String,
        instanceTag: String?,
        rawValue: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let team = await resolvedTeam(teamID)
        try await inner.setConnectionMethod(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            rawValue: rawValue,
            stackUserID: stackUserID,
            teamID: team
        )
    }

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
        guard let target else { return }
        try await remove(
            macDeviceID: macDeviceID,
            instanceTag: target.instanceTag,
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
        // Resolve every scope's account FIRST: the account-wide parked intents
        // must be persisted BEFORE the first suspension a revive can interleave
        // with (the local deletes below). A Mac re-registering during a local
        // delete clears every EXISTING tombstone for its pairing; an intent
        // inserted afterwards would survive the revive and suppress the freshly
        // re-registered pairing in every restore.
        var resolvedAccounts: [String?] = []
        var accountWideIntents: [(account: String, pairingID: String, localTeamID: String?)] = []
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
            resolvedAccounts.append(account)
            if let backupAccount = account ?? lastSignedInAccount {
                accountWideIntents.append((
                    account: backupAccount,
                    pairingID: MobilePairedMac.pairingID(
                        macDeviceID: macDeviceID,
                        instanceTag: scope.instanceTag
                    ),
                    localTeamID: scope.teamID
                ))
            }
        }
        // Account-wide tombstones: the routed per-row intents below cover only
        // LOCALLY KNOWN rows, but backups live in per-team Durable Objects and
        // only restored teams have local rows. The broker revoke covered the
        // pairing account-wide, so park one intent per forgotten pairing under
        // the nil (unknown-destination) scope: it suppresses the pairing in
        // EVERY team's restore, and each verified team snapshot that proves it
        // holds the pairing gets a delete. Parked intents persist until the
        // pairing is revived (re-paired), because any number of teams' backups
        // may still hold it.
        var parkedByAccount: [String: Set<ParkedIntentSeed>] = [:]
        for intent in accountWideIntents {
            parkedByAccount[intent.account, default: []].insert(
                ParkedIntentSeed(pairingID: intent.pairingID, localTeamID: intent.localTeamID)
            )
        }
        for (account, seeds) in parkedByAccount {
            let parkedScope = await nonoptionalScopeKey(account: account, teamID: nil)
            var records = await pendingRecords(scope: parkedScope)
            // Dedupe by identity, not encoding: re-forgetting a pairing must
            // not stack a second stamped copy of the same intent.
            let existing = Set(records.map { raw -> String in
                let record = PendingDeleteRecord(decoding: raw, scopeTeamID: nil)
                return "\(record.pairingID)\u{0}\(record.localTeamID ?? "")"
            })
            let stampMs = now().timeIntervalSince1970 * 1_000
            var changed = false
            for seed in seeds
            where !existing.contains("\(seed.pairingID)\u{0}\(seed.localTeamID ?? "")") {
                // The record keeps the ROW's local team so offline crash
                // recovery replays the exact delete: a nil local team replays
                // only nil-team rows, stranding concrete-team rows whose local
                // delete never landed. Account-wide COVERAGE is unaffected —
                // suppression and echo matching key on the pairing id alone.
                records.insert(
                    PendingDeleteRecord(
                        pairingID: seed.pairingID,
                        localTeamID: seed.localTeamID,
                        stampMs: stampMs
                    ).encoded()
                )
                changed = true
            }
            // Bounded retention: parked intents retire only on revive, so a cap
            // keeps the persisted set and the per-restore scan bounded. Evict
            // oldest-first (unstamped legacy records first — they are oldest by
            // construction); an evicted intent's forget has had the most time
            // to propagate through restores, and losing it degrades to the
            // pre-account-wide behavior for that one pairing.
            if records.count > Self.parkedTombstoneCap {
                let oldestFirst = records.sorted { lhs, rhs in
                    let left = PendingDeleteRecord(decoding: lhs, scopeTeamID: nil)
                    let right = PendingDeleteRecord(decoding: rhs, scopeTeamID: nil)
                    if left.stampMs != right.stampMs { return left.stampMs < right.stampMs }
                    return lhs < rhs
                }
                for raw in oldestFirst.prefix(records.count - Self.parkedTombstoneCap) {
                    records.remove(raw)
                }
                changed = true
            }
            if changed {
                await savePendingRecords(records, scope: parkedScope)
            }
        }
        // The per-row deletes and routed tombstones. A row whose delete throws
        // has its routed intent rolled back; every row is attempted before the
        // first error is rethrown.
        var flushTargets: [String: (account: String, destination: String?)] = [:]
        var firstError: (any Error)?
        for (index, scope) in scopes.enumerated() {
            let macDeviceID = cmxCanonicalDeviceID(scope.macDeviceID)
            let account = resolvedAccounts[index]
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

    /// Device-local Tailscale grants never mirror to the server backup: the
    /// grant's whole point is that a restored row on another device cannot
    /// dial plaintext Tailscale without its own user-entered code.
    public func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws {
        try await inner.authorizeUserTailscaleRoutes(
            macDeviceID: cmxCanonicalDeviceID(macDeviceID),
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: await resolvedTeam(teamID),
            routes: routes
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
        diagnosticLog?.recordAppEvent(
            .pairedMacBackupRefreshStarted,
            correlationID: account
        )
        lastSignedInAccount = account
        // Coalesce with any in-flight restore for this scope so we never run two
        // merges concurrently against the same store.
        let team = (await teamIDProvider()) ?? ""
        let scope = await nonoptionalScopeKey(account: account, teamID: team.isEmpty ? nil : team)
        let restoreTeam = team.isEmpty ? nil : team
        await applyPendingLocalDeletes(scope: scope, account: account, teamID: restoreTeam)
        // Crash recovery must be NETWORK-INDEPENDENT: a parked (account-wide)
        // tombstone whose local delete never landed replays here, from the
        // outbox alone, regardless of which team is selected — the restore's
        // suppression list only runs after a successful backup fetch.
        let parkedScope = await nonoptionalScopeKey(account: account, teamID: nil)
        if parkedScope != scope {
            await applyPendingLocalDeletes(scope: parkedScope, account: account, teamID: nil)
        }
        _ = await flushPendingDeletes(scope: scope, account: account, teamID: restoreTeam)
        let task: Task<RestoreOutcome, Never>
        if let existing = inFlight[scope] {
            task = existing
        } else {
            let restore = PairedMacRestore(store: inner, backup: backup)
            let pendingDeletes = await restoreSuppressions(scope: scope, account: account)
            let boundaryGeneration = restoreBoundary.generation
            let restoreBoundary = restoreBoundary
            let diagnosticLog = diagnosticLog
            let created = Task {
                diagnosticLog?.recordAppEvent(
                    .pairedMacRestoreStarted,
                    correlationID: scope
                )
                let outcome = await restore.run(
                    accountID: account,
                    teamID: restoreTeam,
                    boundary: restoreBoundary,
                    boundaryGeneration: boundaryGeneration,
                    suppressions: pendingDeletes,
                    // Persist where the server SAID this snapshot's records live,
                    // so a restored row forgotten later (the reinstall case, when
                    // no upload ever recorded a mapping) still routes its delete
                    // tombstone to the right team's backup.
                    onResolvedBackupTeam: { [weak self] echoes, resolvedTeamID in
                        await self?.recordResolvedBackupTeams(
                            echoes,
                            restoreTeam: restoreTeam,
                            teamID: resolvedTeamID,
                            account: account
                        )
                    }
                )
                diagnosticLog?.recordAppEvent(
                    outcome.completed
                        ? .pairedMacRestoreSucceeded
                        : .pairedMacRestoreFailed,
                    correlationID: scope,
                    failure: outcome.completed ? nil : .unknown,
                    count: outcome.restored
                )
                return outcome
            }
            inFlight[scope] = created
            task = created
        }
        let generation = resetGeneration
        let outcome = await task.value
        diagnosticLog?.recordAppEvent(
            outcome.completed
                ? .pairedMacBackupRefreshSucceeded
                : .pairedMacBackupRefreshFailed,
            correlationID: scope,
            failure: outcome.completed ? nil : .unknown,
            count: outcome.restored
        )
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
        let matches = try await inner.loadAll(stackUserID: stackUserID, teamID: teamID).filter {
            cmxCanonicalDeviceID($0.macDeviceID) == macDeviceID
                && (!requiresExactInstanceTag
                    || MacPairingKey(
                        macDeviceID: $0.macDeviceID,
                        instanceTag: $0.instanceTag
                    ) == MacPairingKey(
                        macDeviceID: macDeviceID,
                        instanceTag: instanceTag
                    ))
        }
        guard requiresExactInstanceTag || matches.count == 1 else { return nil }
        return matches.first
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
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        diagnosticLog?.recordAppEvent(
            .pairedMacBackupWriteStarted,
            correlationID: pairingID
        )
        let team = await resolvedTeam(teamID)
        let localMacs: [MobilePairedMac]
        do {
            localMacs = try await inner.loadAll(stackUserID: account, teamID: team)
        } catch {
            diagnosticLog?.recordAppEvent(
                .pairedMacBackupWriteFailed,
                correlationID: pairingID,
                failure: DiagnosticFailureKind.classify(error)
            )
            return false
        }
        guard let mac = localMacs.first(where: {
            MacPairingKey(
                macDeviceID: $0.macDeviceID,
                instanceTag: $0.instanceTag
            ) == MacPairingKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        }) else {
            diagnosticLog?.recordAppEvent(
                .pairedMacBackupWriteFailed,
                correlationID: pairingID,
                failure: .localStateUnavailable
            )
            return false
        }
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
        diagnosticLog?.recordAppEvent(
            outcome.succeeded
                ? .pairedMacBackupWriteSucceeded
                : .pairedMacBackupWriteFailed,
            correlationID: pairingID,
            failure: outcome.succeeded ? nil : .unknown
        )
        // Remember where the server SAID it stored this record. A nil-team
        // upload is resolved server-side, and that resolution can drift by the
        // time the record is forgotten; the persisted echo lets the delete
        // tombstone route to the backup the record actually lives in. The
        // mapping is keyed by the ROW's stored team (`mac.teamID`), never the
        // request/display scope: `loadAll(teamID:)` deliberately matches
        // legacy TEAM-LESS rows under a selected team, and the later forget
        // looks the mapping up with the row's own team — a display-team key
        // would never be found for a team-less row.
        if outcome.succeeded, let resolvedTeamID = outcome.resolvedTeamID {
            await backupTeamStore.save(
                resolvedTeamID,
                key: backupTeamKey(
                    account: account,
                    rowTeamID: mac.teamID,
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
        // Crash recovery must be NETWORK-INDEPENDENT: a parked (account-wide)
        // tombstone whose local delete never landed replays here, from the
        // outbox alone, regardless of which team is selected — the restore's
        // suppression list only runs after a successful backup fetch.
        let parkedScope = await nonoptionalScopeKey(account: account, teamID: nil)
        if parkedScope != scope {
            await applyPendingLocalDeletes(scope: parkedScope, account: account, teamID: nil)
        }
        _ = await flushPendingDeletes(scope: scope, account: account, teamID: restoreTeam)
        if restoredScopes.contains(scope) { return }

        let task: Task<RestoreOutcome, Never>
        if let existing = inFlight[scope] {
            task = existing
        } else {
            let restore = PairedMacRestore(store: inner, backup: backup)
            let pendingDeletes = await restoreSuppressions(scope: scope, account: account)
            let boundaryGeneration = restoreBoundary.generation
            let restoreBoundary = restoreBoundary
            let diagnosticLog = diagnosticLog
            let created = Task {
                diagnosticLog?.recordAppEvent(
                    .pairedMacRestoreStarted,
                    correlationID: scope
                )
                let outcome = await restore.run(
                    accountID: account,
                    teamID: restoreTeam,
                    boundary: restoreBoundary,
                    boundaryGeneration: boundaryGeneration,
                    suppressions: pendingDeletes,
                    // Persist where the server SAID this snapshot's records live,
                    // so a restored row forgotten later (the reinstall case, when
                    // no upload ever recorded a mapping) still routes its delete
                    // tombstone to the right team's backup.
                    onResolvedBackupTeam: { [weak self] echoes, resolvedTeamID in
                        await self?.recordResolvedBackupTeams(
                            echoes,
                            restoreTeam: restoreTeam,
                            teamID: resolvedTeamID,
                            account: account
                        )
                    }
                )
                diagnosticLog?.recordAppEvent(
                    outcome.completed
                        ? .pairedMacRestoreSucceeded
                        : .pairedMacRestoreFailed,
                    correlationID: scope,
                    failure: outcome.completed ? nil : .unknown,
                    count: outcome.restored
                )
                return outcome
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
        /// Insertion time (epoch MILLISECONDS) ordering eviction of the
        /// bounded parked set and serving as the forget boundary for revival
        /// classification; 0 for records that predate stamping. Milliseconds,
        /// because flooring to seconds let a server write from the same second
        /// but before the forget classify as a revival. Emitted only when
        /// non-zero, so routed records' encodings — matched by exact string in
        /// `clearPendingDelete(_:)` — are unchanged.
        let stampMs: Double

        /// `pairingID` alone (a legacy record whose local team equals its
        /// scope's team), `pairingID<RS>localTeam`, with "" = team-less, an
        /// `<RS>ms<millis>` third field for stamped records, or a bare
        /// `<RS><seconds>` third field from builds that stamped whole seconds.
        static let separator: Character = "\u{1E}"

        init(pairingID: String, localTeamID: String?, stampMs: Double = 0) {
            self.pairingID = pairingID
            self.localTeamID = localTeamID
            self.stampMs = stampMs
        }

        func encoded() -> String {
            var encoded = "\(pairingID)\(Self.separator)\(localTeamID ?? "")"
            if stampMs > 0 {
                encoded += "\(Self.separator)ms\(Int(stampMs))"
            }
            return encoded
        }

        /// Decode a stored record. A legacy record (no separator) predates the
        /// destination-keyed outbox, where local scope == the record's scope,
        /// so its local team is the scope's own team.
        init(decoding raw: String, scopeTeamID: String?) {
            let parts = raw.split(
                separator: Self.separator,
                maxSplits: 2,
                omittingEmptySubsequences: false
            )
            let identity = MobilePairedMac.pairingIdentity(from: String(parts[0]))
            pairingID = MobilePairedMac.pairingID(
                macDeviceID: identity.macDeviceID,
                instanceTag: identity.instanceTag
            )
            if parts.count == 3 {
                let field = parts[2]
                if field.hasPrefix("ms"), let millis = Int(field.dropFirst(2)) {
                    stampMs = Double(millis)
                } else if let seconds = Int(field) {
                    // A bare integer predates the explicit unit marker and was
                    // stamped in whole seconds.
                    stampMs = Double(seconds) * 1_000
                } else {
                    stampMs = 0
                }
            } else {
                stampMs = 0
            }
            if parts.count >= 2 {
                let team = String(parts[1])
                localTeamID = team.isEmpty ? nil : team
            } else {
                localTeamID = scopeTeamID
            }
        }

    }

    /// One account-wide tombstone to park: the forgotten pairing plus the
    /// captured row's LOCAL team (for exact offline replay).
    private struct ParkedIntentSeed: Hashable {
        let pairingID: String
        let localTeamID: String?
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

    /// The full suppression list for one scope's restore: its own pending
    /// tombstones PLUS the account's PARKED (unknown-destination) ones. A
    /// parked intent is a forget the user was told succeeded; its destination
    /// team is unknown, so EVERY team's restore must refuse to resurrect that
    /// pairing — unless the server wrote the record AFTER the intent (a
    /// revival), which the stamp lets the restore detect. Duplicate pairings
    /// keep their NEWEST stamp.
    private func restoreSuppressions(
        scope: String,
        account: String
    ) async -> [PairedMacRestoreSuppression] {
        var scopeKeys = [scope]
        let parkedScope = await nonoptionalScopeKey(account: account, teamID: nil)
        if parkedScope != scope {
            scopeKeys.append(parkedScope)
        }
        var stampsByPairing: [String: Double] = [:]
        for scopeKey in scopeKeys {
            let scopeTeam = teamID(fromScopeKey: scopeKey)
            for raw in await pendingRecords(scope: scopeKey) {
                let record = PendingDeleteRecord(decoding: raw, scopeTeamID: scopeTeam)
                stampsByPairing[record.pairingID] = max(
                    stampsByPairing[record.pairingID] ?? 0,
                    record.stampMs
                )
            }
        }
        return stampsByPairing.map { pairingID, stampMs in
            PairedMacRestoreSuppression(pairingID: pairingID, stampMs: stampMs)
        }
    }

    /// The team component of a scope key (`account\0team[\0clientScope]`).
    private func teamID(fromScopeKey scope: String) -> String? {
        let parts = scope.split(separator: "\u{0}", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    private func addPendingDelete(_ planned: PlannedTombstone) async {
        var records = await pendingRecords(scope: planned.outboxScope)
        // The PARKED (unknown-destination) scope dedupes by IDENTITY and stays
        // bounded: an account-wide intent for the same pairing already covers a
        // row intent (encodings differ only by the eviction stamp), and the
        // scope retires only on revive, so unchecked inserts would defeat the
        // cap that keeps its size and per-restore scan bounded.
        if planned.destinationTeamID == nil {
            let identity = "\(planned.record.pairingID)\u{0}\(planned.record.localTeamID ?? "")"
            let covered = records.contains { raw in
                let record = PendingDeleteRecord(decoding: raw, scopeTeamID: nil)
                return "\(record.pairingID)\u{0}\(record.localTeamID ?? "")" == identity
            }
            if covered { return }
            records.insert(planned.record.encoded())
            if records.count > Self.parkedTombstoneCap {
                let oldestFirst = records.sorted { lhs, rhs in
                    let left = PendingDeleteRecord(decoding: lhs, scopeTeamID: nil)
                    let right = PendingDeleteRecord(decoding: rhs, scopeTeamID: nil)
                    if left.stampMs != right.stampMs { return left.stampMs < right.stampMs }
                    return lhs < rhs
                }
                for raw in oldestFirst.prefix(records.count - Self.parkedTombstoneCap) {
                    records.remove(raw)
                }
            }
            await savePendingRecords(records, scope: planned.outboxScope)
            return
        }
        records.insert(planned.record.encoded())
        await savePendingRecords(records, scope: planned.outboxScope)
    }

    private func clearPendingDelete(_ planned: PlannedTombstone) async {
        var records = await pendingRecords(scope: planned.outboxScope)
        guard records.remove(planned.record.encoded()) != nil else { return }
        await savePendingRecords(records, scope: planned.outboxScope)
    }

    /// Drop the pending tombstone for THE EXACT ROW that was just re-added
    /// (revive): the intent could sit under its mapped destination scope, its
    /// own team's scope, or the parked nil-team scope, in either encoding.
    /// Only records whose LOCAL team matches the re-added row are cleared —
    /// the destination-keyed outbox can hold same-pairing records for OTHER
    /// local teams (the same pairing forgotten in several teams shares one
    /// destination), and cancelling those would let their forgotten backup
    /// records survive and restore later. A legacy unscoped record decodes its
    /// local team from the scope it sits in, so it matches only in the
    /// re-added row's own scope.
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
        // A re-pair also cancels the ACCOUNT-WIDE parked intents for this
        // EXACT pairing (any recorded local team): the pairing is provably
        // back, so it must not keep being suppressed and deleted from team
        // backups it re-uploads to. The device-wide (tag-less) intent is
        // cleared only by a revive of the untagged pairing itself — one tagged
        // instance returning does not prove the wildcard forget's OTHER tags
        // were re-added, and per-record revival classification already lets
        // the revived pairing through everywhere.
        var candidateTeams: [String?] = [teamID, nil]
        if let mapped { candidateTeams.append(mapped) }
        var cleared = false
        for team in candidateTeams {
            let scope = await nonoptionalScopeKey(account: account, teamID: team)
            var records = await pendingRecords(scope: scope)
            let before = records.count
            records = records.filter { raw in
                let record = PendingDeleteRecord(decoding: raw, scopeTeamID: team)
                if record.pairingID == pairingID && record.localTeamID == teamID {
                    return false
                }
                // Account-wide intents live in the nil scope; their recorded
                // local team is the captured ROW's team (for offline replay)
                // and does not narrow which revive cancels them.
                if team == nil, record.pairingID == pairingID {
                    return false
                }
                return true
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
        let records = await pendingRecords(scope: scope)
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
            // Reentrancy fence, part 1 — retire the sent records ATOMICALLY,
            // before any further suspension: the synchronous cache read and the
            // cache write inside `savePendingRecords` happen in one actor turn,
            // so a re-pair-plus-second-forget interleaving one of the LATER
            // awaits re-adds its (identical) record AFTER retirement and keeps
            // its own retry. Only the records this flush SENT are retired;
            // anything else in the scope survives to its own flush. A sent
            // record already missing from the cache was cleared by a revive
            // DURING the upload — remember it for repair below.
            let current = pendingDeleteIDsByScope[scope] ?? records
            let revivedMidFlight = records.subtracting(current)
            let retained = current.subtracting(records)
            await savePendingRecords(retained, scope: scope)
            // Part 2 — per sent record: a revived record's delete may have
            // landed AFTER its revive on the server, so re-upload its current
            // local row (whose mirror echo also re-saves the mapping); a
            // retired record's mapping is removed.
            for raw in records {
                let record = PendingDeleteRecord(decoding: raw, scopeTeamID: teamID)
                if revivedMidFlight.contains(raw) {
                    let identity = MobilePairedMac.pairingIdentity(from: record.pairingID)
                    _ = await uploadCurrentRecord(
                        macDeviceID: identity.macDeviceID,
                        instanceTag: identity.instanceTag,
                        account: account,
                        teamID: teamID,
                        allowTombstoneRevive: true
                    )
                } else {
                    await backupTeamStore.remove(
                        key: backupTeamKey(
                            account: account,
                            rowTeamID: record.localTeamID,
                            pairingID: record.pairingID
                        )
                    )
                }
            }
            return retained
        }
        // The parked nil-team scope never flushes wholesale and never migrates:
        // a parked intent is an ACCOUNT-WIDE tombstone whose pairing may exist
        // in any number of per-team backups, so no single destination could
        // retire it. It acts through the restore path instead —
        // `suppressedPairingIDs` hides the pairing in every team's restore, and
        // `resolveParkedTombstones` sends a delete to each verified team whose
        // snapshot proves it holds the pairing — until a re-pair revives the
        // pairing and clears the intent.
        return records
    }

}
