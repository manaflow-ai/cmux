import CmuxWorkspaces
import CmuxSidebar
import Darwin
import Foundation

extension DockSplitStore {
    func agentWaitSurfaceSnapshot(panelID: UUID) -> AgentWaitSurfaceSnapshot? {
        guard panels[panelID] != nil else { return nil }
        let authoritativeRecords = agentRuntimeByPanelId[panelID]?
            .authoritativeAgentLifecycleRecords ?? [:]
        let records = authoritativeRecords.isEmpty
            ? detachedSurfaceTransfersByPanelId[panelID]?.agentLifecycleRecords ?? [:]
            : authoritativeRecords
        let occupants = records
            .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
            .map(\.value)
        let occupant = occupants.count == 1 ? occupants[0] : nil
        return AgentWaitSurfaceSnapshot(
            workspaceID: workspaceId,
            surfaceID: panelID,
            paneID: paneId(forPanelId: panelID)?.id,
            occupant: occupant,
            hasAuthoritativeLiveLifecycle: !authoritativeRecords.isEmpty
        )
    }

    private func takeNextDockAgentLifecycleRevision() -> UInt64 {
        let revision = nextAgentLifecycleRevision
        nextAgentLifecycleRevision &+= 1
        return revision
    }

    private func reserveDockAgentLifecycleRevisions(after revision: UInt64) {
        guard nextAgentLifecycleRevision <= revision else { return }
        nextAgentLifecycleRevision = revision &+ 1
    }

    private func publishDockAgentLifecycleTransition(
        _ record: AgentLifecycleRecord,
        state: AgentLifecyclePublicState,
        previousState: AgentLifecyclePublicState?,
        panelID: UUID
    ) {
        CmuxEventBus.shared.publishAgentStateChanged(
            workspaceID: workspaceId,
            surfaceID: panelID,
            paneID: paneId(forPanelId: panelID)?.id,
            record: record,
            state: state,
            previousState: previousState
        )
    }

    private func publishRemovedDockAgentLifecycleRecords(
        from recordsBeforeMutation: [UUID: [String: AgentLifecycleRecord]]
    ) {
        for (panelID, records) in recordsBeforeMutation {
            for (key, record) in records where
                agentRuntimeByPanelId[panelID]?
                    .authoritativeAgentLifecycleRecords[key] == nil {
                publishDockAgentLifecycleTransition(
                    record,
                    state: .exit,
                    previousState: record.publicState,
                    panelID: panelID
                )
            }
        }
    }

    func clearSessionRestoreState(panelId: UUID, publishLifecycleExit: Bool = true) {
        let authoritativeRecords = agentRuntimeByPanelId[panelId]?
            .authoritativeAgentLifecycleRecords ?? [:]
        let records = authoritativeRecords.isEmpty
            ? detachedSurfaceTransfersByPanelId[panelId]?.agentLifecycleRecords ?? [:]
            : authoritativeRecords
        if publishLifecycleExit, !records.isEmpty {
            for record in records.values {
                publishDockAgentLifecycleTransition(
                    record,
                    state: .exit,
                    previousState: record.publicState,
                    panelID: panelId
                )
            }
        }
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.snapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.resumeStatesByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        managedAgentResumeBindingsByPanelId.removeValue(forKey: panelId)
        invalidatedCachedTransferAgentSessionPanelIds.remove(panelId)
        replacedCachedTransferAgentSessionPanelIds.remove(panelId)
        restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
        replaceAgentRuntime(nil, panelId: panelId)
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        guard let terminal = panels[panelId] as? TerminalPanel else { return }
        let previousState = terminal.shellActivity.state
        terminal.updateShellActivityState(state)
        if previousState != state,
           let pendingTitle = advanceTransferredRestoredPanelTitleBoundary(
               panelId: panelId,
               state: state
           ) {
            terminal.updateTitle(pendingTitle)
        }
        let restoredAgent = restoredAgentLifecycle.snapshotsByPanelId[panelId]

        switch (state, restoredAgentLifecycle.resumeStatesByPanelId[panelId]) {
        case (.commandRunning, .some(.awaitingAutoResumeCommand)):
            restoredAgentLifecycle.resumeStatesByPanelId[panelId] = .autoResumeCommandRunning
        case (.commandRunning, .some(.manualResumeAvailable)):
            restoredAgentLifecycle.snapshotsByPanelId.removeValue(forKey: panelId)
            restoredAgentLifecycle.resumeStatesByPanelId.removeValue(forKey: panelId)
            retireAgentHookResumeBinding(panelId: panelId)
        case (.promptIdle, .some(.autoResumeCommandRunning)),
             (.promptIdle, .some(.observedAgentCommandRunning)):
            if restoredAgent != nil {
                markRestoredAgentCompleted(panelId: panelId)
            } else {
                restoredAgentLifecycle.resumeStatesByPanelId.removeValue(forKey: panelId)
            }
            restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
            retireAgentHookResumeBinding(panelId: panelId, matching: restoredAgent)
        default:
            break
        }
    }

    /// Keeps a Workspace-owned restore boundary coherent while its live panel
    /// temporarily belongs to a Dock.
    private func advanceTransferredRestoredPanelTitleBoundary(
        panelId: UUID,
        state: PanelShellActivityState
    ) -> String? {
        guard var transfer = detachedSurfaceTransfersByPanelId[panelId],
              var boundary = transfer.restoredPanelTitleBoundary else {
            return nil
        }
        let pendingTitle = boundary.observe(shellState: state)
        transfer.restoredPanelTitleBoundary = boundary.isReleased ? nil : boundary
        setDetachedSurfaceTransfer(transfer, forPanelID: panelId)
        return pendingTitle
    }

    func adoptSessionRestoreState(from detached: Workspace.DetachedSurfaceTransfer) {
        invalidatedCachedTransferAgentSessionPanelIds.remove(detached.panelId)
        replacedCachedTransferAgentSessionPanelIds.remove(detached.panelId)
        restoredAgentLifecycle.seedTransferredState(
            panelId: detached.panelId,
            snapshot: detached.restorableAgent,
            resumeState: detached.restorableAgentResumeState,
            completedGeneration: detached.restoredAgentCompletedGeneration
        )
        managedAgentResumeBindingsByPanelId.removeValue(forKey: detached.panelId)
        if let resumeBinding = detached.resumeBinding {
            surfaceResumeBindingsByPanelId[detached.panelId] = resumeBinding
        }
        if let transferredManagedBinding = detached.resolvedManagedAgentResumeBinding {
            managedAgentResumeBindingsByPanelId[detached.panelId] = transferredManagedBinding
        }
        if let directory = detached.restoredResumeSessionWorkingDirectory {
            restoredResumeSessionWorkingDirectoriesByPanelId[detached.panelId] = directory
        }
        let transferredRevisions = detached.agentLifecycleRecords.values.map(\.revision)
            + (detached.agentRuntime?.authoritativeAgentLifecycleRecords.values.map(\.revision) ?? [])
        if let maximumRevision = transferredRevisions.max() {
            reserveDockAgentLifecycleRevisions(after: maximumRevision)
        }
        replaceAgentRuntime(detached.agentRuntime, panelId: detached.panelId)
    }

    func configureAgentHibernationResume(for terminal: TerminalPanel) {
        terminal.onRequestAgentHibernationResume = { [weak self, weak terminal] focus in
            guard let self, let terminal else { return false }
            return self.resumeAgentHibernation(panelId: terminal.id, focus: focus)
        }
    }

    @discardableResult
    func resumeAgentHibernation(panelId: UUID, focus: Bool) -> Bool {
        guard let terminal = panels[panelId] as? TerminalPanel,
              terminal.isAgentHibernated else {
            return false
        }
        let preparation = terminal.prepareAgentHibernationResume()
        guard preparation.didResume else { return false }
        if restoredAgentLifecycle.snapshotsByPanelId[panelId] != nil {
            restoredAgentLifecycle.resumeStatesByPanelId[panelId] = preparation.queuedStartupInput
                ? .awaitingAutoResumeCommand
                : .manualResumeAvailable
            restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        }
        AgentHibernationController.shared.recordTerminalFocus(
            workspaceId: workspaceId,
            panelId: panelId
        )
        if focus { focusPanel(panelId) }
        return true
    }

    private func retireAgentHookResumeBinding(
        panelId: UUID,
        matching restoredAgent: SessionRestorableAgentSnapshot? = nil
    ) {
        guard var binding = managedAgentResumeBinding(panelId: panelId)
            ?? surfaceResumeBindingsByPanelId[panelId],
            binding.isAgentHookBinding else {
            return
        }
        if let restoredAgent {
            let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard checkpointId == nil || checkpointId == restoredAgent.sessionId else {
                return
            }
        }
        let originalBinding = binding
        binding.autoResume = false
        if binding.hasCompleteManagedSessionIdentity {
            managedAgentResumeBindingsByPanelId[panelId] = binding
        }
        if let effectiveBinding = surfaceResumeBindingsByPanelId[panelId] {
            if effectiveBinding == originalBinding || effectiveBinding.isSameManagedSession(as: binding) {
                surfaceResumeBindingsByPanelId[panelId] = binding
            }
        } else {
            surfaceResumeBindingsByPanelId[panelId] = binding
        }
    }

    func markRestoredAgentCompleted(panelId: UUID) {
        // A live completion belongs to the current session generation. Keep
        // older cached metadata invalidated, but no longer classify this
        // current tombstone as the cached generation that was replaced.
        replacedCachedTransferAgentSessionPanelIds.remove(panelId)
        let runtimeIdentities = Set(
            (agentRuntimeByPanelId[panelId]
                ?? detachedSurfaceTransfersByPanelId[panelId]?.agentRuntime)?
                .agentPIDProcessIdentities.values.map { $0 } ?? []
        )
        restoredAgentLifecycle.markCompleted(
            panelId: panelId,
            observation: SharedLiveAgentIndex.shared.index?.entry(
                workspaceId: detachedSurfaceTransfersByPanelId[panelId]?.sessionRestoreWorkspaceId
                    ?? workspaceId,
                panelId: panelId
            ),
            runtimeProcessIdentities: runtimeIdentities
        )
    }

    func agentRuntimeStatusEntry(key: String, panelId: UUID) -> SidebarStatusEntry? {
        agentRuntimeByPanelId[panelId]?.statusEntries[key]
    }

    func setAgentRuntimeStatusEntry(
        _ entry: SidebarStatusEntry,
        key: String,
        panelId: UUID
    ) {
        mutateAgentRuntime(panelId: panelId) {
            $0.statusEntries[key] = entry
        }
    }

    func clearAgentRuntimeStatusEntry(key: String, panelId: UUID) {
        mutateAgentRuntime(panelId: panelId) {
            $0.statusEntries.removeValue(forKey: key)
        }
    }

    @discardableResult
    func recordAgentPID(
        key: String,
        pid: pid_t,
        panelId: UUID,
        expectedLifecycleSessionID: String? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil
    ) -> Bool {
        recordAgentPIDOutcome(
            key: key,
            pid: pid,
            panelId: panelId,
            expectedLifecycleSessionID: expectedLifecycleSessionID,
            expectedPIDStartSeconds: expectedPIDStartSeconds,
            expectedPIDStartMicroseconds: expectedPIDStartMicroseconds
        ).didReplaceRuntime
    }

    private func recordAgentPIDOutcome(
        key: String,
        pid: pid_t,
        panelId: UUID,
        expectedLifecycleSessionID: String? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil,
        commit: Bool = true
    ) -> (
        accepted: Bool,
        didReplaceRuntime: Bool,
        matchedExistingProcessGeneration: Bool
    ) {
        if let expectedLifecycleSessionID {
            guard let runtime = agentRuntimeByPanelId[panelId],
                  runtime.agentPIDKeys.contains(key),
                  let statusKey = Self.structuredAgentStatusKey(
                      forAgentPIDKey: key,
                      runtime: runtime
                  ),
                  key == "\(statusKey).\(expectedLifecycleSessionID)",
                  runtime.agentLifecycleSessionIDs[statusKey] == expectedLifecycleSessionID else {
                return (false, false, false)
            }
        }
        let processIdentity = Workspace.agentPIDProcessIdentity(pid: pid)
        let expectedProcessIdentity: AgentPIDProcessIdentity?
        switch (expectedPIDStartSeconds, expectedPIDStartMicroseconds) {
        case (nil, nil):
            expectedProcessIdentity = nil
        case let (startSeconds?, startMicroseconds?):
            expectedProcessIdentity = AgentPIDProcessIdentity(
                pid: pid,
                startSeconds: startSeconds,
                startMicroseconds: startMicroseconds
            )
        case (nil, _?), (_?, nil):
            return (false, false, false)
        }
        var didReplaceProcessGeneration = false
        var matchedExistingProcessGeneration = false
        var staleOwnerPanelIDs: [UUID] = []
        if let expectedProcessIdentity {
            if let ownerPanelID = agentRuntimePanelIDByPIDKey[key],
               let runtime = agentRuntimeByPanelId[ownerPanelID] {
                if let previousIdentity = runtime.agentPIDProcessIdentities[key] {
                    if previousIdentity == expectedProcessIdentity {
                        matchedExistingProcessGeneration = true
                        guard runtime.agentPIDs[key] == nil || runtime.agentPIDs[key] == pid else {
                            return (false, false, false)
                        }
                    } else {
                        guard previousIdentity.startedBefore(expectedProcessIdentity) else {
                            return (false, false, false)
                        }
                        didReplaceProcessGeneration = true
                    }
                } else if let previousPID = runtime.agentPIDs[key] {
                    if previousPID != pid {
                        guard Workspace.agentPIDProcessIdentity(pid: previousPID) == nil else {
                            return (false, false, false)
                        }
                        didReplaceProcessGeneration = true
                    }
                } else {
                    return (false, false, false)
                }
            }

            if let targetRuntime = agentRuntimeByPanelId[panelId] {
                let structuredKeys = targetRuntime.agentPIDKeys.filter {
                    $0 != key && Self.isStructuredAgentHookPIDKey($0, runtime: targetRuntime)
                }
                for existingKey in structuredKeys {
                    if let existingIdentity = targetRuntime.agentPIDProcessIdentities[existingKey] {
                        if existingIdentity == expectedProcessIdentity {
                            matchedExistingProcessGeneration = true
                        }
                        guard existingIdentity == expectedProcessIdentity
                                || existingIdentity.startedBefore(expectedProcessIdentity) else {
                            return (false, false, false)
                        }
                    } else if let existingPID = targetRuntime.agentPIDs[existingKey] {
                        if existingPID != pid {
                            guard Workspace.agentPIDProcessIdentity(pid: existingPID) == nil else {
                                return (false, false, false)
                            }
                        }
                    } else {
                        return (false, false, false)
                    }
                }

                let incomingStatusKey = Self.agentStatusKey(
                    forAgentPIDKey: key,
                    runtime: targetRuntime
                )
                for lifecycleKey in targetRuntime.agentLifecycleStates.keys where
                    lifecycleKey != incomingStatusKey
                        && AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(lifecycleKey) {
                    guard structuredKeys.contains(where: {
                        Self.agentStatusKey(forAgentPIDKey: $0, runtime: targetRuntime)
                            == lifecycleKey
                    }) else {
                        return (false, false, false)
                    }
                }
            }

            // Preserve an exact recorded generation after process exit, while
            // requiring a live kernel match for every new/replacing claim.
            guard matchedExistingProcessGeneration
                    || processIdentity == expectedProcessIdentity else {
                return (false, false, false)
            }

            if let ownerPanelID = agentRuntimePanelIDByPIDKey[key],
               ownerPanelID != panelId {
                staleOwnerPanelIDs = [ownerPanelID]
            }
        }
        guard commit else {
            return (true, false, matchedExistingProcessGeneration)
        }
        var authoritativeRecordsBeforeMutation: [UUID: [String: AgentLifecycleRecord]] = [:]
        for affectedPanelID in staleOwnerPanelIDs + [panelId] {
            if let records = agentRuntimeByPanelId[affectedPanelID]?
                .authoritativeAgentLifecycleRecords {
                authoritativeRecordsBeforeMutation[affectedPanelID] = records
            }
        }
        for staleOwnerPanelID in staleOwnerPanelIDs {
            mutateAgentRuntime(panelId: staleOwnerPanelID) { runtime in
                _ = Self.clearAgentPID(key: key, clearStatus: true, runtime: &runtime)
            }
        }
        let recordedProcessIdentity = expectedProcessIdentity ?? processIdentity
        var didReplaceRuntime = false
        mutateAgentRuntime(panelId: panelId) { runtime in
            if Self.isStructuredAgentHookPIDKey(key, runtime: runtime) {
                let staleKeys = runtime.agentPIDKeys.filter {
                    $0 != key && Self.isStructuredAgentHookPIDKey($0, runtime: runtime)
                }
                for staleKey in staleKeys {
                    Self.clearAgentPID(
                        key: staleKey,
                        clearStatus: true,
                        runtime: &runtime
                    )
                }
                didReplaceRuntime = !staleKeys.isEmpty
            }
            runtime.agentPIDs[key] = pid
            if let recordedProcessIdentity {
                runtime.agentPIDProcessIdentities[key] = recordedProcessIdentity
            } else {
                runtime.agentPIDProcessIdentities.removeValue(forKey: key)
            }
            runtime.agentPIDKeys.insert(key)
        }
        publishRemovedDockAgentLifecycleRecords(
            from: authoritativeRecordsBeforeMutation
        )
        return (
            true,
            didReplaceRuntime || didReplaceProcessGeneration,
            matchedExistingProcessGeneration
        )
    }

    @discardableResult
    func setAgentLifecycle(
        key: String,
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState,
        sessionID: String? = nil,
        startsNewOccupant: Bool = false,
        expectedPIDKey: String? = nil,
        expectedPID: pid_t? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil,
        requireExistingOwner: Bool = false,
        apply: Bool = true
    ) -> Bool {
        guard panels[panelId] != nil else { return false }
        let expectedProcessIdentity: AgentPIDProcessIdentity?
        switch (expectedPID, expectedPIDStartSeconds, expectedPIDStartMicroseconds) {
        case (nil, nil, nil):
            expectedProcessIdentity = nil
        case let (pid?, startSeconds?, startMicroseconds?):
            expectedProcessIdentity = AgentPIDProcessIdentity(
                pid: pid,
                startSeconds: startSeconds,
                startMicroseconds: startMicroseconds
            )
        case _:
            return false
        }
        let normalizedSessionID: String?
        if let sessionID {
            let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSessionID.isEmpty else { return false }
            normalizedSessionID = trimmedSessionID
        } else {
            normalizedSessionID = nil
        }
        var matchedExistingProcessGeneration = false
        var processGenerationReplacedOccupant = false
        var lifecycleRecordWasRemovedByPIDMutation = false
        let previous = agentRuntimeByPanelId[panelId]?
            .authoritativeAgentLifecycleRecords[key]
        let transferredSessionOwner = normalizedSessionID.flatMap { sessionID in
            agentRuntimeByPanelId[panelId]?.agentLifecycleSessionIDs[key]
                .map { $0 == sessionID }
        } == true
        let transferredProcessOwner: Bool = {
            guard let expectedProcessIdentity,
                  let expectedPIDKey,
                  let runtime = agentRuntimeByPanelId[panelId] else {
                return false
            }
            return runtime.agentPIDProcessIdentities[expectedPIDKey] == expectedProcessIdentity
        }()
        guard !requireExistingOwner
            || previous != nil
            || transferredSessionOwner
            || transferredProcessOwner else {
            return false
        }
        let hasDifferentAuthoritativeSession = previous?.sessionID != nil
            && normalizedSessionID != nil
            && previous?.sessionID != normalizedSessionID
        // Validate a delayed turn/status hook before its PID mutation can clear
        // the current occupant's lifecycle record. Only SessionStart may rotate
        // a different authoritative session.
        if hasDifferentAuthoritativeSession && !startsNewOccupant {
            return false
        }
        let lifecycleRecordBeforePIDMutation = agentRuntimeByPanelId[panelId]?
            .authoritativeAgentLifecycleRecords[key]
        switch (expectedPIDKey, expectedPID) {
        case let (expectedPIDKey?, expectedPID?):
            let currentRuntime = agentRuntimeByPanelId[panelId]
            let expectedStatusKey = currentRuntime.map {
                Self.agentStatusKey(forAgentPIDKey: expectedPIDKey, runtime: $0)
            } ?? String(expectedPIDKey.prefix { $0 != "." })
            guard expectedPID > 0, expectedStatusKey == key else { return false }
            let establishesNewPIDOwner = startsNewOccupant
                && (
                    expectedPIDKey == key
                        || normalizedSessionID.map({ expectedPIDKey == "\(key).\($0)" }) == true
                )
            if expectedProcessIdentity != nil || establishesNewPIDOwner {
                let outcome = recordAgentPIDOutcome(
                    key: expectedPIDKey,
                    pid: expectedPID,
                    panelId: panelId,
                    expectedPIDStartSeconds: expectedProcessIdentity?.startSeconds,
                    expectedPIDStartMicroseconds: expectedProcessIdentity?.startMicroseconds,
                    commit: apply
                )
                guard outcome.accepted else { return false }
                matchedExistingProcessGeneration = outcome.matchedExistingProcessGeneration
                processGenerationReplacedOccupant = expectedProcessIdentity != nil
                    && !outcome.matchedExistingProcessGeneration
                lifecycleRecordWasRemovedByPIDMutation = lifecycleRecordBeforePIDMutation != nil
                    && agentRuntimeByPanelId[panelId]?
                        .authoritativeAgentLifecycleRecords[key] == nil
            } else {
                guard let runtime = currentRuntime,
                      runtime.agentPIDs[expectedPIDKey] == expectedPID else {
                    return false
                }
            }
        case (nil, nil):
            guard expectedProcessIdentity == nil else { return false }
        case (nil, _?), (_?, nil):
            return false
        }
        if let normalizedSessionID {
            let sessionPIDKey = "\(key).\(normalizedSessionID)"
            let hasSessionPIDOwner = agentRuntimeByPanelId[panelId]?
                .agentPIDKeys.contains(sessionPIDKey) == true
                || (startsNewOccupant && expectedPIDKey == sessionPIDKey && expectedPID != nil)
            let hasSessionOwner = agentRuntimeByPanelId[panelId]?
                .agentLifecycleSessionIDs[key] == normalizedSessionID
            // A durable hook record plus an exact live process generation can
            // recover a Dock lifecycle owner after the runtime cache was lost;
            // a session-only retry still needs the existing lifecycle owner.
            let hasProcessBackedSessionOwner = expectedProcessIdentity != nil
                && hasSessionPIDOwner
            guard startsNewOccupant || hasSessionPIDOwner || hasSessionOwner,
                  startsNewOccupant || hasSessionOwner || hasProcessBackedSessionOwner else {
                return false
            }
        }
        guard apply else { return true }
        let isDuplicateAuthoritativeStart = startsNewOccupant
            && !processGenerationReplacedOccupant
            && (
                (normalizedSessionID != nil && previous?.sessionID == normalizedSessionID)
                    || (normalizedSessionID == nil && matchedExistingProcessGeneration)
            )
        let isReplacement = previous != nil
            && (hasDifferentAuthoritativeSession
                || processGenerationReplacedOccupant
                || (startsNewOccupant && !isDuplicateAuthoritativeStart))
        if let previous, isReplacement, !lifecycleRecordWasRemovedByPIDMutation {
            publishDockAgentLifecycleTransition(
                previous,
                state: .exit,
                previousState: previous.publicState,
                panelID: panelId
            )
        }
        var authoritativeRecord: AgentLifecycleRecord
        if var existing = previous, !isReplacement {
            existing.state = lifecycle
            if existing.sessionID == nil, normalizedSessionID != nil {
                existing.sessionID = normalizedSessionID
            }
            authoritativeRecord = existing
        } else {
            authoritativeRecord = AgentLifecycleRecord(
                agent: key,
                state: lifecycle,
                sessionID: normalizedSessionID,
                revision: takeNextDockAgentLifecycleRevision()
            )
        }
        mutateAgentRuntime(panelId: panelId) {
            $0.agentLifecycleStates[key] = lifecycle
            if let retainedSessionID = authoritativeRecord.sessionID {
                $0.agentLifecycleSessionIDs[key] = retainedSessionID
            } else {
                $0.agentLifecycleSessionIDs.removeValue(forKey: key)
            }
            $0.authoritativeAgentLifecycleRecords[key] = authoritativeRecord
        }
        if previous == nil || isReplacement || previous?.state != lifecycle
            || previous?.sessionID != authoritativeRecord.sessionID {
            publishDockAgentLifecycleTransition(
                authoritativeRecord,
                state: authoritativeRecord.publicState,
                previousState: isReplacement ? nil : previous?.publicState,
                panelID: panelId
            )
        }
        return true
    }

    @discardableResult
    func clearAgentPID(
        key: String,
        panelId: UUID,
        clearStatus: Bool,
        expectedLifecycleSessionID: String? = nil,
        expectedPID: pid_t? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil,
        requireOwnedKey: Bool = false
    ) -> Bool {
        if let expectedLifecycleSessionID {
            guard let runtime = agentRuntimeByPanelId[panelId],
                  let statusKey = Self.structuredAgentStatusKey(
                      forAgentPIDKey: key,
                      runtime: runtime
                  ),
                  key == "\(statusKey).\(expectedLifecycleSessionID)",
                  runtime.agentLifecycleSessionIDs[statusKey] == expectedLifecycleSessionID,
                  runtime.agentPIDKeys.contains(key)
                      || runtime.authoritativeAgentLifecycleRecords[statusKey] != nil else {
                return false
            }
        }
        if let expectedPID {
            guard agentRuntimeByPanelId[panelId]?.agentPIDs[key] == expectedPID else {
                return false
            }
            switch (expectedPIDStartSeconds, expectedPIDStartMicroseconds) {
            case (nil, nil):
                break
            case let (startSeconds?, startMicroseconds?):
                guard agentRuntimeByPanelId[panelId]?.agentPIDProcessIdentities[key]
                    == AgentPIDProcessIdentity(
                        pid: expectedPID,
                        startSeconds: startSeconds,
                        startMicroseconds: startMicroseconds
                    ) else {
                    return false
                }
            case (nil, _?), (_?, nil):
                return false
            }
        } else if expectedPIDStartSeconds != nil || expectedPIDStartMicroseconds != nil {
            return false
        }
        if requireOwnedKey,
           agentRuntimeByPanelId[panelId]?.agentPIDKeys.contains(key) != true {
            return false
        }
        let removedStatusKey = agentRuntimeByPanelId[panelId].map {
            Self.agentStatusKey(forAgentPIDKey: key, runtime: $0)
        }
        let removedLifecycleRecord = removedStatusKey.flatMap {
            agentRuntimeByPanelId[panelId]?
                .authoritativeAgentLifecycleRecords[$0]
        }
        var didChange = false
        mutateAgentRuntime(panelId: panelId) {
            didChange = Self.clearAgentPID(
                key: key,
                clearStatus: clearStatus,
                runtime: &$0
            )
        }
        if didChange,
           let removedStatusKey,
           let removedLifecycleRecord,
           agentRuntimeByPanelId[panelId]?
               .authoritativeAgentLifecycleRecords[removedStatusKey] == nil {
            publishDockAgentLifecycleTransition(
                removedLifecycleRecord,
                state: .exit,
                previousState: removedLifecycleRecord.publicState,
                panelID: panelId
            )
        }
        return didChange
    }

    private func mutateAgentRuntime(
        panelId: UUID,
        mutation: (inout Workspace.DetachedAgentRuntimeState) -> Void
    ) {
        guard panels[panelId] != nil else { return }
        let previousAuthoritativeRecords = agentRuntimeByPanelId[panelId]?
            .authoritativeAgentLifecycleRecords ?? [:]
        var runtime = agentRuntimeByPanelId[panelId] ?? Workspace.DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: [:],
            agentPIDs: [:],
            agentPIDProcessIdentities: [:],
            agentPIDKeys: []
        )
        mutation(&runtime)
        let shouldKeep = Self.shouldKeepAgentRuntime(runtime)
        let nextRuntime = shouldKeep ? runtime : nil
        replaceAgentRuntime(nextRuntime, panelId: panelId)
        let nextAuthoritativeRecords = nextRuntime?.authoritativeAgentLifecycleRecords ?? [:]
        if nextAuthoritativeRecords != previousAuthoritativeRecords {
            synchronizeTransferredLifecycleRecords(
                panelID: panelId,
                records: nextAuthoritativeRecords
            )
        }
    }

    /// Replaces one Dock runtime while keeping PID-key ownership O(1).
    private func replaceAgentRuntime(
        _ runtime: Workspace.DetachedAgentRuntimeState?,
        panelId: UUID
    ) {
        let previousKeys = agentRuntimeByPanelId[panelId].map(Self.indexedPIDKeys) ?? []
        let currentKeys = runtime.map(Self.indexedPIDKeys) ?? []
        if runtime != nil {
            for key in currentKeys {
                guard let previousOwner = agentRuntimePanelIDByPIDKey[key],
                      previousOwner != panelId,
                      var previousRuntime = agentRuntimeByPanelId[previousOwner] else {
                    continue
                }
                let recordsBeforeMutation = [
                    previousOwner: previousRuntime.authoritativeAgentLifecycleRecords
                ]
                let previousAuthoritativeRecords = previousRuntime.authoritativeAgentLifecycleRecords
                _ = Self.clearAgentPID(
                    key: key,
                    clearStatus: true,
                    runtime: &previousRuntime
                )
                replaceAgentRuntime(
                    Self.shouldKeepAgentRuntime(previousRuntime) ? previousRuntime : nil,
                    panelId: previousOwner
                )
                if previousRuntime.authoritativeAgentLifecycleRecords != previousAuthoritativeRecords {
                    synchronizeTransferredLifecycleRecords(
                        panelID: previousOwner,
                        records: previousRuntime.authoritativeAgentLifecycleRecords
                    )
                }
                publishRemovedDockAgentLifecycleRecords(from: recordsBeforeMutation)
            }
        }
        for key in previousKeys.subtracting(currentKeys)
            where agentRuntimePanelIDByPIDKey[key] == panelId {
            agentRuntimePanelIDByPIDKey.removeValue(forKey: key)
        }
        if let runtime {
            agentRuntimeByPanelId[panelId] = runtime
            for key in currentKeys {
                agentRuntimePanelIDByPIDKey[key] = panelId
            }
        } else {
            agentRuntimeByPanelId.removeValue(forKey: panelId)
        }
        if var transfer = detachedSurfaceTransfersByPanelId[panelId] {
            transfer.agentRuntime = runtime
            detachedSurfaceTransfersByPanelId[panelId] = transfer
        }
    }

    /// Keeps the transfer fallback in lockstep with authoritative Dock-owned
    /// lifecycle mutations, without overwriting entry-time records during a
    /// restore adoption that has no live runtime yet.
    private func synchronizeTransferredLifecycleRecords(
        panelID: UUID,
        records: [String: AgentLifecycleRecord]
    ) {
        guard var transfer = detachedSurfaceTransfersByPanelId[panelID] else { return }
        transfer.agentLifecycleRecords = records
        detachedSurfaceTransfersByPanelId[panelID] = transfer
    }

    private static func indexedPIDKeys(
        _ runtime: Workspace.DetachedAgentRuntimeState
    ) -> Set<String> {
        runtime.agentPIDKeys
            .union(runtime.agentPIDs.keys)
            .union(runtime.agentPIDProcessIdentities.keys)
    }

    private static func shouldKeepAgentRuntime(
        _ runtime: Workspace.DetachedAgentRuntimeState
    ) -> Bool {
        !runtime.statusEntries.isEmpty
            || !runtime.agentPIDs.isEmpty
            || !runtime.agentPIDKeys.isEmpty
            || !runtime.agentLifecycleStates.isEmpty
            || !runtime.agentLifecycleSessionIDs.isEmpty
            || !runtime.authoritativeAgentLifecycleRecords.isEmpty
    }

    @discardableResult
    private static func clearAgentPID(
        key: String,
        clearStatus: Bool,
        runtime: inout Workspace.DetachedAgentRuntimeState
    ) -> Bool {
        let statusKey = agentStatusKey(forAgentPIDKey: key, runtime: runtime)
        var didChange = false
        if runtime.agentPIDs.removeValue(forKey: key) != nil { didChange = true }
        if runtime.agentPIDProcessIdentities.removeValue(forKey: key) != nil { didChange = true }
        if runtime.agentPIDKeys.remove(key) != nil { didChange = true }
        if runtime.agentLifecycleStates.removeValue(forKey: statusKey) != nil {
            didChange = true
        }
        if runtime.agentLifecycleSessionIDs.removeValue(forKey: statusKey) != nil {
            didChange = true
        }
        if runtime.authoritativeAgentLifecycleRecords.removeValue(forKey: statusKey) != nil {
            didChange = true
        }
        if clearStatus,
           !runtime.agentPIDKeys.contains(where: {
               agentStatusKey(forAgentPIDKey: $0, runtime: runtime) == statusKey
           }),
           runtime.statusEntries.removeValue(forKey: statusKey) != nil {
            didChange = true
        }
        return didChange
    }

    private static func isStructuredAgentHookPIDKey(
        _ key: String,
        runtime: Workspace.DetachedAgentRuntimeState
    ) -> Bool {
        AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(
            agentStatusKey(forAgentPIDKey: key, runtime: runtime)
        )
    }

    private static func structuredAgentStatusKey(
        forAgentPIDKey key: String,
        runtime: Workspace.DetachedAgentRuntimeState
    ) -> String? {
        let statusKey = agentStatusKey(forAgentPIDKey: key, runtime: runtime)
        return AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey)
            ? statusKey
            : nil
    }

    static func agentStatusKey(
        forAgentPIDKey key: String,
        runtime: Workspace.DetachedAgentRuntimeState
    ) -> String {
        if runtime.statusEntries[key] != nil {
            return key
        }
        guard let dotIndex = key.firstIndex(of: ".") else {
            return key
        }
        return String(key[..<dotIndex])
    }
}
