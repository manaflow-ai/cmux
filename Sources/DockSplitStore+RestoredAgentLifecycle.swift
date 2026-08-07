import CmuxWorkspaces
import CmuxSidebar
import Darwin
import Foundation

extension DockSplitStore {
    func agentWaitSurfaceSnapshot(panelID: UUID) -> AgentWaitSurfaceSnapshot? {
        guard panels[panelID] != nil else { return nil }
        let occupants = detachedSurfaceTransfersByPanelId[panelID]?.agentLifecycleRecords
            .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
            .map(\.value)
            ?? []
        let occupant = occupants.count == 1 ? occupants[0] : nil
        return AgentWaitSurfaceSnapshot(
            workspaceID: workspaceId,
            surfaceID: panelID,
            paneID: paneId(forPanelId: panelID)?.id,
            occupant: occupant,
            hasAuthoritativeLiveLifecycle: false
        )
    }

    func clearSessionRestoreState(panelId: UUID) {
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.snapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.resumeStatesByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        managedAgentResumeBindingsByPanelId.removeValue(forKey: panelId)
        invalidatedCachedTransferAgentSessionPanelIds.remove(panelId)
        replacedCachedTransferAgentSessionPanelIds.remove(panelId)
        restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
        agentRuntimeByPanelId.removeValue(forKey: panelId)
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
        if let runtime = detached.agentRuntime {
            agentRuntimeByPanelId[detached.panelId] = runtime
        } else {
            agentRuntimeByPanelId.removeValue(forKey: detached.panelId)
        }
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
        if let expectedLifecycleSessionID {
            guard let runtime = agentRuntimeByPanelId[panelId],
                  runtime.agentPIDKeys.contains(key),
                  let statusKey = Self.structuredAgentStatusKey(
                      forAgentPIDKey: key,
                      runtime: runtime
                  ),
                  key == "\(statusKey).\(expectedLifecycleSessionID)",
                  runtime.agentLifecycleSessionIDs[statusKey] == expectedLifecycleSessionID else {
                return false
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
            return false
        }
        var didReplaceProcessGeneration = false
        var matchedExistingProcessGeneration = false
        if let expectedProcessIdentity {
            for runtime in agentRuntimeByPanelId.values where
                runtime.agentPIDKeys.contains(key)
                    || runtime.agentPIDs[key] != nil
                    || runtime.agentPIDProcessIdentities[key] != nil {
                if let previousIdentity = runtime.agentPIDProcessIdentities[key] {
                    if previousIdentity == expectedProcessIdentity {
                        matchedExistingProcessGeneration = true
                        guard runtime.agentPIDs[key] == nil || runtime.agentPIDs[key] == pid else {
                            return false
                        }
                    } else {
                        guard previousIdentity.startedBefore(expectedProcessIdentity) else {
                            return false
                        }
                        didReplaceProcessGeneration = true
                    }
                } else if let previousPID = runtime.agentPIDs[key] {
                    if previousPID != pid {
                        guard Workspace.agentPIDProcessIdentity(pid: previousPID) == nil else {
                            return false
                        }
                        didReplaceProcessGeneration = true
                    }
                } else {
                    return false
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
                            return false
                        }
                    } else if let existingPID = targetRuntime.agentPIDs[existingKey] {
                        if existingPID != pid {
                            guard Workspace.agentPIDProcessIdentity(pid: existingPID) == nil else {
                                return false
                            }
                        }
                    } else {
                        return false
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
                        return false
                    }
                }
            }

            // Preserve an exact recorded generation after process exit, while
            // requiring a live kernel match for every new/replacing claim.
            guard matchedExistingProcessGeneration
                    || processIdentity == expectedProcessIdentity else {
                return false
            }

            let staleOwnerPanelIDs = agentRuntimeByPanelId.compactMap { ownerPanelID, runtime in
                ownerPanelID != panelId
                    && (runtime.agentPIDKeys.contains(key)
                        || runtime.agentPIDs[key] != nil
                        || runtime.agentPIDProcessIdentities[key] != nil)
                    ? ownerPanelID
                    : nil
            }
            for staleOwnerPanelID in staleOwnerPanelIDs {
                mutateAgentRuntime(panelId: staleOwnerPanelID) { runtime in
                    _ = Self.clearAgentPID(key: key, clearStatus: true, runtime: &runtime)
                }
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
        return didReplaceRuntime || didReplaceProcessGeneration
    }

    func setAgentLifecycle(
        key: String,
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState,
        sessionID: String? = nil,
        startsNewOccupant: Bool = false,
        expectedPIDKey: String? = nil,
        expectedPID: pid_t? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil
    ) {
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
            return
        }
        switch (expectedPIDKey, expectedPID) {
        case let (expectedPIDKey?, expectedPID?):
            guard expectedPID > 0 else { return }
            if let expectedProcessIdentity {
                _ = recordAgentPID(
                    key: expectedPIDKey,
                    pid: expectedPID,
                    panelId: panelId,
                    expectedPIDStartSeconds: expectedProcessIdentity.startSeconds,
                    expectedPIDStartMicroseconds: expectedProcessIdentity.startMicroseconds
                )
            }
            guard let runtime = agentRuntimeByPanelId[panelId],
                  runtime.agentPIDs[expectedPIDKey] == expectedPID,
                  Self.agentStatusKey(forAgentPIDKey: expectedPIDKey, runtime: runtime) == key else {
                return
            }
            if let expectedProcessIdentity,
               runtime.agentPIDProcessIdentities[expectedPIDKey] != expectedProcessIdentity {
                return
            }
        case (nil, nil):
            guard expectedProcessIdentity == nil else { return }
        case (nil, _?), (_?, nil):
            return
        }
        if let sessionID {
            guard let runtime = agentRuntimeByPanelId[panelId],
                  runtime.agentPIDKeys.contains("\(key).\(sessionID)"),
                  startsNewOccupant
                    || runtime.agentLifecycleSessionIDs[key] == sessionID else {
                return
            }
        }
        mutateAgentRuntime(panelId: panelId) {
            $0.agentLifecycleStates[key] = lifecycle
            if let sessionID {
                $0.agentLifecycleSessionIDs[key] = sessionID
            } else {
                $0.agentLifecycleSessionIDs.removeValue(forKey: key)
            }
        }
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
                  runtime.agentPIDKeys.contains(key),
                  let statusKey = Self.structuredAgentStatusKey(
                      forAgentPIDKey: key,
                      runtime: runtime
                  ),
                  key == "\(statusKey).\(expectedLifecycleSessionID)",
                  runtime.agentLifecycleSessionIDs[statusKey] == expectedLifecycleSessionID else {
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
        var didChange = false
        mutateAgentRuntime(panelId: panelId) {
            didChange = Self.clearAgentPID(
                key: key,
                clearStatus: clearStatus,
                runtime: &$0
            )
        }
        return didChange
    }

    private func mutateAgentRuntime(
        panelId: UUID,
        mutation: (inout Workspace.DetachedAgentRuntimeState) -> Void
    ) {
        guard panels[panelId] != nil else { return }
        var runtime = agentRuntimeByPanelId[panelId] ?? Workspace.DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: [:],
            agentPIDs: [:],
            agentPIDProcessIdentities: [:],
            agentPIDKeys: []
        )
        mutation(&runtime)
        let shouldKeep = !runtime.statusEntries.isEmpty
            || !runtime.agentPIDs.isEmpty
            || !runtime.agentPIDKeys.isEmpty
            || !runtime.agentLifecycleStates.isEmpty
            || !runtime.agentLifecycleSessionIDs.isEmpty
        if shouldKeep {
            agentRuntimeByPanelId[panelId] = runtime
        } else {
            agentRuntimeByPanelId.removeValue(forKey: panelId)
        }
        if var transfer = detachedSurfaceTransfersByPanelId[panelId] {
            transfer.agentRuntime = shouldKeep ? runtime : nil
            detachedSurfaceTransfersByPanelId[panelId] = transfer
        }
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
