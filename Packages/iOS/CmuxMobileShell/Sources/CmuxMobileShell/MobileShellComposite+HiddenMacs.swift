import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
internal import OSLog

private let hiddenMacsLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

@MainActor
extension MobileShellComposite {
    func storedHiddenMacDeviceIDs(scopeKey key: String) async -> Set<String> {
        if let cached = hiddenMacDeviceIDsByScope[key] { return cached }
        let loaded = await hiddenMacStore.load(scope: key)
        if let cached = hiddenMacDeviceIDsByScope[key] {
            return cached
        }
        hiddenMacDeviceIDsByScope[key] = loaded
        return loaded
    }

    func hiddenMacDeviceIDs(scope: MobileShellScopeSnapshot) async -> Set<String> {
        let key = pairedMacScopeKey(scope)
        let scoped = await storedHiddenMacDeviceIDs(scopeKey: key)
        guard scope.teamID != nil else { return scoped }
        let userWide = await storedHiddenMacDeviceIDs(
            scopeKey: pairedMacScopeKey(userWideScope(from: scope))
        )
        return scoped.union(userWide)
    }

    func visibleStoredPairedMacs(
        from loadedMacs: [MobilePairedMac],
        scope: MobileShellScopeSnapshot
    ) async -> [MobilePairedMac] {
        let hiddenIDs = await hiddenMacDeviceIDs(scope: scope)
        return visibleStoredPairedMacs(from: loadedMacs, hiddenIDs: hiddenIDs)
    }

    func visibleStoredPairedMacs(
        from loadedMacs: [MobilePairedMac],
        hiddenIDs: Set<String>
    ) -> [MobilePairedMac] {
        return loadedMacs.filter {
            !hiddenIDs.contains($0.id)
                && ($0.instanceTag != nil || !hiddenIDs.contains($0.macDeviceID))
        }
    }

    /// Clears rowless markers written by the legacy delete flow.
    ///
    /// Both pairing ids and raw device ids were historically stored as markers,
    /// so either form keeps the marker when it matches a local row.
    func migrateLegacyHiddenMacMarkers(
        loadedMacs: [MobilePairedMac],
        hiddenIDs: Set<String>,
        scope: MobileShellScopeSnapshot
    ) async -> Set<String> {
        // A bare device marker is backed only by an untagged legacy row. A
        // Stable/Nightly row backs its exact composite pairing id instead.
        let rowBackedIDs = Set(loadedMacs.map(\.id))
        let rowlessIDs = hiddenIDs.subtracting(rowBackedIDs)
        guard !rowlessIDs.isEmpty else { return hiddenIDs }

        var scopeKeys = Set([pairedMacScopeKey(scope)])
        if scope.teamID != nil {
            scopeKeys.insert(pairedMacScopeKey(userWideScope(from: scope)))
        }
        for scopeKey in scopeKeys {
            for rowlessID in rowlessIDs {
                await clearHiddenMacDeviceID(rowlessID, scopeKey: scopeKey)
            }
        }
        hiddenMacsLog.info(
            "legacy hidden-marker migration cleared=\(rowlessIDs.count) kept=\(hiddenIDs.count - rowlessIDs.count) rows=\(loadedMacs.count)"
        )
        return hiddenIDs.subtracting(rowlessIDs)
    }

    func isHiddenMacDeviceID(
        _ macDeviceID: String,
        instanceTag: String? = nil,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        let ids = await hiddenMacDeviceIDs(scope: scope)
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        // A bare marker is the legacy untagged pairing only. It must never
        // hide a Stable/Nightly sibling that shares the physical device id.
        return ids.contains(pairingID)
            || (macInstanceTagAuthority.normalize(instanceTag) == nil
                && ids.contains(macDeviceID))
    }

    func rememberHiddenMacDeviceID(
        _ macDeviceID: String,
        scope: MobileShellScopeSnapshot,
        includeUserWideScope: Bool = false
    ) async {
        guard !macDeviceID.isEmpty else { return }
        await rememberHiddenMacDeviceID(macDeviceID, scopeKey: pairedMacScopeKey(scope))
        if includeUserWideScope, scope.teamID != nil {
            await rememberHiddenMacDeviceID(
                macDeviceID,
                scopeKey: pairedMacScopeKey(userWideScope(from: scope))
            )
        }
        let identity = MobilePairedMac.pairingIdentity(from: macDeviceID)
        for index in registryDevices.indices
        where registryDevices[index].deviceId == identity.macDeviceID {
            registryDevices[index].instances.removeAll { instance in
                CmxMacAppInstanceIdentity(
                    macDeviceID: identity.macDeviceID,
                    instanceTag: instance.tag
                ).id == CmxMacAppInstanceIdentity(
                    macDeviceID: identity.macDeviceID,
                    instanceTag: identity.instanceTag
                ).id
            }
        }
        registryDevices.removeAll { $0.instances.isEmpty }
    }

    func rememberHiddenMacDeviceID(_ macDeviceID: String, scopeKey key: String) async {
        var ids = await storedHiddenMacDeviceIDs(scopeKey: key)
        ids.insert(macDeviceID)
        hiddenMacDeviceIDsByScope[key] = ids
        await hiddenMacStore.save(ids, scope: key)
    }

    func clearHiddenMacDeviceID(
        _ macDeviceID: String,
        instanceTag: String? = nil,
        scope: MobileShellScopeSnapshot?
    ) async {
        guard !macDeviceID.isEmpty, let scope else { return }
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        var ids = Set([pairingID])
        if macInstanceTagAuthority.normalize(instanceTag) == nil {
            ids.insert(macDeviceID)
        }
        for id in ids {
            await clearHiddenMacDeviceID(id, scopeKey: pairedMacScopeKey(scope))
        }
        if scope.teamID != nil {
            for id in ids {
                await clearHiddenMacDeviceID(
                    id,
                    scopeKey: pairedMacScopeKey(userWideScope(from: scope))
                )
            }
        }
    }

    func clearHiddenMacDeviceID(_ macDeviceID: String, scopeKey key: String) async {
        var ids = await storedHiddenMacDeviceIDs(scopeKey: key)
        guard ids.remove(macDeviceID) != nil else { return }
        hiddenMacDeviceIDsByScope[key] = ids
        await hiddenMacStore.save(ids, scope: key)
        if ids.isEmpty {
            hiddenMacDeviceIDsByScope[key] = nil
        }
    }

    /// Revokes a hidden computer's account bindings, then drops its local row.
    ///
    /// The revoke is the meaningful action: it removes the binding from every
    /// device on the account. On success the paired-Mac row and its hidden
    /// marker are cleared so the computer disappears from every section; a Mac
    /// that is still online re-registers a fresh binding and reappears on its
    /// next connect. Returns `false` (leaving the row untouched) when no forget
    /// capability is wired or the revoke fails, so the caller can surface an
    /// error instead of a silent no-op.
    public func forgetHiddenComputer(_ computer: MobileHiddenComputer) async -> Bool {
        let startedAt = appDiagnosticNow()
        recordAppEvent(.computerForgetStarted, correlationID: computer.id)
        // Capture the scope BEFORE the network revoke so local cleanup targets the
        // account/team that owned the row, not whatever scope is current after the
        // await (the user can sign out or switch accounts while the call is in
        // flight).
        guard let scope = await currentScopeSnapshot() else {
            recordAppEvent(
                .computerForgetFailed,
                correlationID: computer.id,
                startedAt: startedAt,
                failure: .authorizationFailed
            )
            return false
        }
        // Clear the durable row(s) and hidden marker, even if the scope
        // changed while this call was in flight. Every row is deleted against
        // ITS OWN stored scope, never the live display scope: a team-less row
        // is visible under any selected team (legacy visibility), so deleting
        // with the display team would miss it and it would resurface once the
        // marker cleared. For a tag-less row cleanup is device-wide for the
        // pinned account: every account-owned row of
        // the device, across teams, in ONE batched store call whose backup
        // tombstones flush once per destination — per-row deletion would issue
        // one sequential backup request per row, and a device can carry up to
        // a large development fleet's worth of rows. Rows owned by other
        // accounts stay.
        let cleaned = await deleteStoredPairedMacRows(
            for: computer,
            pinnedAccountID: computer.stackUserID ?? scope.userID,
            displayScope: scope
        )
        // ONE refresh for the whole cleanup, and only after COMPLETE success.
        // Refreshing per deleted row re-runs the paired list load (and with it
        // the backup restore fetch) and the registry fetch for every sibling.
        // After a PARTIAL failure the markers were deliberately kept as the
        // retry owner, but the batch may have deleted some rows already — the
        // refresh's rowless-marker migration would see those markers as
        // rowless and clear them, so the hidden entry the user retries from
        // would vanish while a failed sibling keeps its revoked binding.
        if cleaned {
            await refreshAfterForget(displayScope: scope)
        }
        recordAppEvent(
            cleaned ? .computerForgetSucceeded : .computerForgetFailed,
            correlationID: computer.id,
            startedAt: startedAt,
            failure: cleaned ? nil : .unknown
        )
        return cleaned
    }

    /// The single post-forget refresh: reload the paired list and registry and
    /// drop the saved reconnect hint once the last stored Mac is gone. Skipped
    /// when the display scope changed mid-forget (the new scope's own loads
    /// already reflect its stores).
    private func refreshAfterForget(displayScope: MobileShellScopeSnapshot) async {
        guard await isScopeCurrent(displayScope) else { return }
        await loadPairedMacs()
        await loadRegistryDevices()
        // Mirror the hide path: once the last stored Mac is gone, drop the saved
        // reconnect hint so the app does not keep trying to redial a forgotten Mac.
        clearSavedMacHintWhenNoStoredMacsRemainIfNeeded()
    }

    /// Deletes every row a forget covers — the exact forgotten row, plus (for a
    /// tag-less wildcard forget) every account-owned instance of the device
    /// across teams — as ONE batched store call, then clears their hidden
    /// markers.
    ///
    /// The wildcard revoke kills the device's bindings for the WHOLE account,
    /// across teams — an offline Mac never re-registers, so any row left behind
    /// (in another team, or another tag) makes the supposedly forgotten
    /// computer reappear when the user switches teams or restores. Enumeration
    /// uses the cross-team `loadAllInstances` (the ordinary team-scoped read
    /// cannot see past the display team); an enumeration FAILURE is a cleanup
    /// failure — the revoke already succeeded account-wide, so silently
    /// claiming success would leave dead rows whose bindings are gone. Rows
    /// owned by other accounts still hold live bindings and must survive.
    /// Markers are cleared only after the batch succeeds, so a failed cleanup
    /// keeps the computer hidden and retryable rather than resurfacing it.
    private func deleteStoredPairedMacRows(
        for computer: MobileHiddenComputer,
        pinnedAccountID: String,
        displayScope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard let pairedMacStore else {
            await clearHiddenMacDeviceID(
                computer.macDeviceID,
                instanceTag: computer.instanceTag,
                scope: displayScope
            )
            return true
        }
        let primary = MobilePairedMacExactScope(
            macDeviceID: computer.macDeviceID,
            instanceTag: computer.instanceTag,
            stackUserID: pinnedAccountID,
            teamID: computer.teamID
        )
        var scopes = [primary]
        // Cross-team sibling cleanup runs for EVERY forget: the broker binding
        // is account-wide, so revoking it kills the binding every team's copy
        // of the pairing uses. A tagged forget revoked exactly the (device,
        // tag) binding — other teams' SAME-TAG rows are dead, different-tag
        // rows keep their own live bindings and survive. A tag-less forget's
        // wildcard revoke covered every tag, so its cleanup does too.
        let rows: [MobilePairedMac]
        do {
            rows = try await pairedMacStore.loadAllInstances(
                macDeviceID: computer.macDeviceID,
                stackUserID: pinnedAccountID
            )
        } catch {
            hiddenMacsLog.error(
                "forget hidden computer sibling enumeration failed: \(String(describing: error), privacy: .private)"
            )
            return false
        }
        for row in rows
        where row.stackUserID == pinnedAccountID
            && macInstanceTagAuthority.sameStoredAuthority(
                row.instanceTag,
                computer.instanceTag
            )
            && !(macInstanceTagAuthority.sameStoredAuthority(
                row.instanceTag,
                primary.instanceTag
            ) && row.teamID == primary.teamID) {
            scopes.append(MobilePairedMacExactScope(
                macDeviceID: row.macDeviceID,
                instanceTag: row.instanceTag,
                stackUserID: pinnedAccountID,
                teamID: row.teamID
            ))
        }
        do {
            try await pairedMacStore.removeExactScopes(scopes)
        } catch {
            hiddenMacsLog.error(
                "forget hidden computer row removal failed: \(String(describing: error), privacy: .private)"
            )
            // The batch deliberately attempts EVERY row, so some rows may be
            // gone despite the failure — and a deleted row can never be
            // re-enumerated on retry, so its markers must be cleared NOW or a
            // re-registering Mac stays unexpectedly hidden in that team
            // forever. Re-enumerate: scopes with no surviving row are the
            // completed deletions. Clearing is NARROW — only the deleted row's
            // own team scope and the user-wide key, never the display scope:
            // the FAILED scope (the retry owner) shares the pairing's marker
            // ids in the display scope, and the wide clear would erase the
            // hidden entry the user retries from. If even the re-enumeration
            // fails, clear nothing — markers err on the side of staying hidden
            // and retryable.
            if let survivors = try? await pairedMacStore.loadAllInstances(
                macDeviceID: computer.macDeviceID,
                stackUserID: pinnedAccountID
            ) {
                let survivorKeys = Set(survivors.map { row in
                    "\(row.instanceTag ?? "")\u{0}\(row.teamID ?? "")"
                })
                for scope in scopes {
                    let scopeKey = "\(scope.instanceTag ?? "")\u{0}\(scope.teamID ?? "")"
                    if survivorKeys.contains(scopeKey) {
                        // A SURVIVING failed scope needs a durable retry entry
                        // in ITS OWN team: normally only the displayed row was
                        // hidden, and once the deleted primary's marker turns
                        // rowless and migrates away, this sibling — whose
                        // binding is already revoked — would resurface as a
                        // normal computer with nothing left to retry from.
                        await rememberHiddenMacDeviceID(
                            MobilePairedMac.pairingID(
                                macDeviceID: scope.macDeviceID,
                                instanceTag: scope.instanceTag
                            ),
                            scopeKey: makePairedMacScopeKey(
                                userID: displayScope.userID,
                                teamID: scope.teamID
                            )
                        )
                        continue
                    }
                    guard scope.teamID != displayScope.teamID else { continue }
                    let ids = [
                        scope.macDeviceID,
                        MobilePairedMac.pairingID(
                            macDeviceID: scope.macDeviceID,
                            instanceTag: scope.instanceTag
                        ),
                    ]
                    for id in ids {
                        await clearHiddenMacDeviceID(
                            id,
                            scopeKey: makePairedMacScopeKey(
                                userID: displayScope.userID,
                                teamID: scope.teamID
                            )
                        )
                        await clearHiddenMacDeviceID(
                            id,
                            scopeKey: makePairedMacScopeKey(
                                userID: displayScope.userID,
                                teamID: nil
                            )
                        )
                    }
                }
            }
            return false
        }
        // Cleared only after the rows are gone, so a still-online Mac that
        // re-registers is not re-hidden by a stale marker.
        for scope in scopes {
            await clearForgottenRowMarkers(scope: scope, displayScope: displayScope)
        }
        return true
    }

    /// Clears one deleted row's hidden markers. Markers are stored per
    /// (user, team): one may live under the display scope (where the user hid
    /// the row) AND under the row's OWN team (the same pairing can be hidden
    /// from several teams), so clear both — a marker left in another team
    /// would keep a re-registering Mac unexpectedly hidden there,
    /// contradicting the forget confirmation that it reappears on its next
    /// connect.
    private func clearForgottenRowMarkers(
        scope: MobilePairedMacExactScope,
        displayScope: MobileShellScopeSnapshot
    ) async {
        await clearHiddenMacDeviceID(
            scope.macDeviceID,
            instanceTag: scope.instanceTag,
            scope: displayScope
        )
        if scope.teamID != displayScope.teamID {
            await clearHiddenMacDeviceID(
                scope.macDeviceID,
                instanceTag: scope.instanceTag,
                scope: MobileShellScopeSnapshot(
                    userID: displayScope.userID,
                    teamID: scope.teamID,
                    generation: displayScope.generation
                )
            )
        }
    }

    /// Unhides one stored pairing without requiring network access.
    public func unhideMacDeviceID(
        _ macDeviceID: String,
        instanceTag: String? = nil
    ) async {
        await enqueueUnhideMacDeviceID(
            macDeviceID,
            instanceTag: instanceTag
        ).value
    }

    /// Starts an owned unhide operation for a row visibility switch.
    public func requestUnhideMacDeviceID(
        _ macDeviceID: String,
        instanceTag: String? = nil
    ) {
        _ = enqueueUnhideMacDeviceID(macDeviceID, instanceTag: instanceTag)
    }

    private func enqueueUnhideMacDeviceID(
        _ macDeviceID: String,
        instanceTag: String?
    ) -> Task<Void, Never> {
        enqueueComputerVisibilityMutation(
            computerID: MobilePairedMac.pairingID(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        ) { store in
            await store.performUnhideMacDeviceID(
                macDeviceID,
                instanceTag: instanceTag
            )
        }
    }

    private func performUnhideMacDeviceID(
        _ macDeviceID: String,
        instanceTag: String?
    ) async {
        let correlationID = MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        guard let scope = await currentScopeSnapshot() else {
            recordAppEvent(
                .computerUnhidden,
                correlationID: correlationID,
                failure: .authorizationFailed
            )
            return
        }
        await clearHiddenMacDeviceID(
            macDeviceID,
            instanceTag: instanceTag,
            scope: scope
        )
        guard !Task.isCancelled,
              await isScopeCurrent(scope),
              !Task.isCancelled else { return }
        await loadPairedMacs()
        guard !Task.isCancelled else { return }
        await loadRegistryDevices()
        recordAppEvent(.computerUnhidden, correlationID: correlationID)
    }

    /// Hides the legacy untagged computer represented by a visible stored Mac id.
    ///
    /// Tagged row actions must use
    /// ``hideStoredPairedMacEntries(representativeID:aliasIDs:)`` so a physical
    /// Mac's sibling app instances remain visible.
    public func hideMac(macDeviceID: String) async {
        await hideStoredPairedMacEntries(
            representativeID: MobilePairedMac.pairingID(
                macDeviceID: macDeviceID,
                instanceTag: nil
            ),
            aliasIDs: [macDeviceID]
        )
    }

    /// Hides one exact tagged app instance without hiding sibling instances.
    public func hideMac(macDeviceID: String, instanceTag: String?) async {
        guard let scope = await currentScopeSnapshot() else { return }
        let targets = pairedMacsForIdentityMatching.filter {
            MacPairingKey($0) == MacPairingKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        }
        guard !targets.isEmpty else { return }
        await hideStoredPairedMacs(targets, scope: scope)
    }

    /// Hides the stored pairing entries represented by one visible computer row.
    ///
    /// Raw device IDs in `aliasIDs` inherit the representative's instance tag
    /// before matching, while already-composite pairing IDs retain their embedded
    /// tag. Targets are then selected by exact ``MobilePairedMac/id`` equality.
    /// - Parameters:
    ///   - representativeID: The visible row's composite pairing ID.
    ///   - aliasIDs: Stored IDs coalesced into that row. An empty array falls
    ///     back to `representativeID`.
    public func hideStoredPairedMacEntries(
        representativeID: String,
        aliasIDs: [String]
    ) async {
        await enqueueHideStoredPairedMacEntries(
            representativeID: representativeID,
            aliasIDs: aliasIDs,
            refreshRegistry: false
        ).value
    }

    /// Starts an owned hide operation for a row visibility switch.
    public func requestHideStoredPairedMacEntries(
        representativeID: String,
        aliasIDs: [String]
    ) {
        _ = enqueueHideStoredPairedMacEntries(
            representativeID: representativeID,
            aliasIDs: aliasIDs,
            refreshRegistry: true
        )
    }

    private func enqueueHideStoredPairedMacEntries(
        representativeID: String,
        aliasIDs: [String],
        refreshRegistry: Bool
    ) -> Task<Void, Never> {
        enqueueComputerVisibilityMutation(computerID: representativeID) { store in
            await store.performHideStoredPairedMacEntries(
                representativeID: representativeID,
                aliasIDs: aliasIDs
            )
            if refreshRegistry, !Task.isCancelled {
                await store.loadRegistryDevices()
            }
        }
    }

    private func performHideStoredPairedMacEntries(
        representativeID: String,
        aliasIDs: [String]
    ) async {
        guard !representativeID.isEmpty,
              let scope = await currentScopeSnapshot() else { return }
        let representative = MobilePairedMac.pairingIdentity(from: representativeID)
        let targetPairingIDs: Set<String> = Set(
            ([representativeID] + aliasIDs).compactMap { storedID in
                guard !storedID.isEmpty else { return nil }
                let identity = MobilePairedMac.pairingIdentity(from: storedID)
                return MobilePairedMac.pairingID(
                    macDeviceID: identity.macDeviceID,
                    instanceTag: identity.instanceTag ?? representative.instanceTag
                )
            }
        )
        let targets = pairedMacsForIdentityMatching.filter {
            targetPairingIDs.contains($0.id)
        }
        guard !targets.isEmpty else { return }
        await hideStoredPairedMacs(targets, scope: scope)
    }

    private func enqueueComputerVisibilityMutation(
        computerID: String,
        operation: @escaping @MainActor (MobileShellComposite) async -> Void
    ) -> Task<Void, Never> {
        let previousTask = computerVisibilityMutationTasksByID[computerID]
        let operationID = UUID()
        computerVisibilityMutationOperationIDsByID[computerID] = operationID
        computerVisibilityMutationIDs.insert(computerID)

        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self else { return }
            defer {
                self.finishComputerVisibilityMutation(
                    computerID: computerID,
                    operationID: operationID
                )
            }
            guard !Task.isCancelled else { return }
            await operation(self)
        }
        computerVisibilityMutationTasksByID[computerID] = task
        return task
    }

    func cancelComputerVisibilityMutations() {
        let tasks = Array(computerVisibilityMutationTasksByID.values)
        computerVisibilityMutationIDs = []
        for task in tasks {
            task.cancel()
        }
        // Keep each cancelled task as the serial tail until its rollback ends.
        // A request in the next account/team scope must await that cleanup before
        // writing a newer durable visibility preference for the same computer.
    }

    private func finishComputerVisibilityMutation(
        computerID: String,
        operationID: UUID
    ) {
        guard computerVisibilityMutationOperationIDsByID[computerID] == operationID else {
            return
        }
        computerVisibilityMutationTasksByID[computerID] = nil
        computerVisibilityMutationOperationIDsByID[computerID] = nil
        computerVisibilityMutationIDs.remove(computerID)
    }

    /// Hides exactly one stored paired-Mac row.
    public func hideStoredMac(macDeviceID: String) async {
        await hideStoredPairedMacEntries(
            representativeID: MobilePairedMac.pairingID(
                macDeviceID: macDeviceID,
                instanceTag: nil
            ),
            aliasIDs: [macDeviceID]
        )
    }

    /// Hides exactly one tagged stored pairing.
    public func hideStoredMac(macDeviceID: String, instanceTag: String?) async {
        guard let scope = await currentScopeSnapshot() else { return }
        let targets = pairedMacsForIdentityMatching.filter {
            MacPairingKey($0) == MacPairingKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        }
        guard !targets.isEmpty else { return }
        await hideStoredPairedMacs(targets, scope: scope)
    }

    private func hideStoredPairedMacs(
        _ targets: [MobilePairedMac],
        scope: MobileShellScopeSnapshot
    ) async {
        guard !targets.isEmpty else { return }
        let correlationID = targets[0].id
        let targetPairingIDs = Set(targets.map(\.id))
        let targetPhysicalIDs = Set(targets.map(\.macDeviceID))
        let teamlessLegacyIDs = Set(targets.filter { $0.teamID == nil }.map(\.id))
        for mac in targets {
            await rememberHiddenMacDeviceID(
                mac.id,
                scope: scope,
                includeUserWideScope: teamlessLegacyIDs.contains(mac.id)
            )
        }
        guard !Task.isCancelled,
              await isScopeCurrent(scope),
              !Task.isCancelled else {
            for pairingID in targetPairingIDs {
                await clearHiddenMacDeviceID(pairingID, scope: scope)
            }
            recordAppEvent(
                .computerHidden,
                correlationID: correlationID,
                failure: .cancelled,
                count: targets.count
            )
            return
        }

        invalidateStoredMacReconnectAttempt()
        let foregroundPairingID = foregroundMacDeviceID.map {
            MobilePairedMac.pairingID(
                macDeviceID: $0,
                instanceTag: connectedMacInstanceTag
            )
        }
        // With a live foreground identity whose TAG is known, only hiding that
        // EXACT pairing may disconnect it: stored `isActive` persists
        // asynchronously after promotion, so a stale active row for the
        // previous sibling must not tear down the build that is actually
        // foreground now. Without a proven live tag the bare device pairing
        // cannot name a build, so stored `isActive` remains the authority.
        let isActiveMac = foregroundPairingID.map { pairingID in
            targetPairingIDs.contains(pairingID)
                || (macInstanceTagAuthority.normalize(connectedMacInstanceTag) == nil
                    && targets.contains(where: \.isActive))
        } ?? targets.contains(where: \.isActive)
        if isActiveMac {
            disconnectLiveConnection(preservingOtherMacWorkspaceState: true)
        }

        let remainingPhysicalIDs = Set(pairedMacsForIdentityMatching
            .filter { !targetPairingIDs.contains($0.id) }
            .map(\.macDeviceID))
        // Subscriptions, workspace entries, and feed snapshots are keyed per
        // pairing: tear down exactly the hidden pairings' entries, whether or
        // not a sibling instance remains visible.
        for pairingID in targetPairingIDs {
            let ownerKey = MacPairingKey(pairingID: pairingID)
            if let subscription = secondaryMacSubscriptions[ownerKey] {
                subscription.cancel()
                secondaryMacSubscriptions[ownerKey] = nil
            }
            workspacesByMac[ownerKey] = nil
            removeNotificationFeedSnapshot(macDeviceID: pairingID)
        }
        // The foreground pairing's feed snapshot may live under the bare
        // DEVICE key. Hiding it while a sibling pairing stays visible skips
        // the fully-hidden prune below, so remove that spelling explicitly.
        if let foregroundPairingID, targetPairingIDs.contains(foregroundPairingID) {
            let identity = MobilePairedMac.pairingIdentity(from: foregroundPairingID)
            removeNotificationFeedSnapshot(macDeviceID: identity.macDeviceID)
        }
        let fullyHiddenPhysicalIDs = targetPhysicalIDs.subtracting(remainingPhysicalIDs)
        for id in fullyHiddenPhysicalIDs {
            pruneWorkspaceStateForHiddenMac(id)
            removeNotificationFeedSnapshot(macDeviceID: id)
        }

        guard !Task.isCancelled,
              await isScopeCurrent(scope),
              !Task.isCancelled else { return }
        await loadPairedMacs()
        clearSavedMacHintWhenNoStoredMacsRemainIfNeeded()
        recordAppEvent(
            .computerHidden,
            correlationID: correlationID,
            count: targets.count
        )
    }

    /// Removes every workspace snapshot owned by a hidden stored Mac identity.
    func pruneWorkspaceStateForHiddenMac(_ storedMacID: String) {
        guard !storedMacID.isEmpty else { return }
        if foregroundMacDeviceID == storedMacID {
            foregroundMacDeviceID = nil
        }
        let pruned = workspacesByMac.reduce(into: [MacPairingKey: MacWorkspaceState]()) { result, entry in
            let (key, state) = entry
            guard !key.isOnDevice(storedMacID), state.macDeviceID != storedMacID else { return }
            let filteredWorkspaces = state.workspaces.filter { $0.macDeviceID != storedMacID }
            var filteredState = state
            filteredState.workspaces = filteredWorkspaces
            result[key] = filteredState
        }
        if pruned != workspacesByMac {
            workspacesByMac = pruned
        }
    }

    func updateHiddenComputers(
        loadedMacs: [MobilePairedMac],
        hiddenIDs: Set<String>
    ) {
        let entries = loadedMacs.compactMap { mac -> MobileHiddenComputer? in
            guard hiddenIDs.contains(mac.id)
                || (mac.instanceTag == nil && hiddenIDs.contains(mac.macDeviceID)) else {
                return nil
            }
            return MobileHiddenComputer(
                id: mac.id,
                macDeviceID: mac.macDeviceID,
                instanceTag: mac.instanceTag,
                displayName: mac.resolvedName,
                customColor: mac.customColor,
                customIcon: mac.customIcon,
                stackUserID: mac.stackUserID,
                teamID: mac.teamID
            )
        }
        hiddenComputers = entries.sorted {
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        hasHiddenComputers = !hiddenComputers.isEmpty
    }
}
