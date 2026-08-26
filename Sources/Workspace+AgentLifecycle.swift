import CmuxWorkspaces
import Foundation

extension Workspace {
    func allowsAgentContinuation(forPanelId panelId: UUID) -> Bool {
        restoredAgentResumeStatesByPanelId[panelId] != .completedAgentExit ||
            restoredAgentSnapshotForContinuation(panelId: panelId) != nil
    }

    func restoredAgentSnapshotForContinuation(
        panelId: UUID
    ) -> SessionRestorableAgentSnapshot? {
        restoredAgentLifecycle.continuationSnapshot(
            panelId: panelId,
            observation: SharedLiveAgentIndex.shared.index?.entry(
                workspaceId: id,
                panelId: panelId
            ),
            currentProcessIdentity: Self.agentPIDProcessIdentity(pid:)
        )
    }

    func reconcileCompletedRestoredAgent(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry
    ) {
        restoredAgentLifecycle.reconcileCompletedAgent(
            panelId: panelId,
            observation: observation,
            currentProcessIdentity: Self.agentPIDProcessIdentity(pid:)
        )
    }

    func markRestoredAgentCompleted(
        panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot
    ) {
        let runtimeProcessIdentities = Set((agentPIDKeysByPanelId[panelId] ?? []).compactMap {
            agentPIDProcessIdentitiesByKey[$0]
        })
        restoredAgentLifecycle.markCompleted(
            panelId: panelId,
            observation: SharedLiveAgentIndex.shared.index?.entry(
                workspaceId: id,
                panelId: panelId
            ),
            runtimeProcessIdentities: runtimeProcessIdentities
        )
    }

    func restoredAgentResumeStateForAcceptedSnapshot(panelId: UUID) -> RestoredAgentResumeState {
        panelShellActivityStates[panelId] == .commandRunning
            ? .observedAgentCommandRunning
            : .manualResumeAvailable
    }

    func updateRestoredAgentResumeState(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot,
        shellState: PanelShellActivityState
    ) {
        switch shellState {
        case .commandRunning:
            switch restoredAgentResumeStatesByPanelId[panelId] {
            case .some(.awaitingAutoResumeCommand):
                restoredAgentResumeStatesByPanelId[panelId] = .autoResumeCommandRunning
            case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning),
                 .some(.completedAgentExit):
                break
            case .some(.manualResumeAvailable), nil:
                invalidateRestoredAgentSnapshot(panelId: panelId, restoredAgent: restoredAgent)
            }
        case .promptIdle:
            switch restoredAgentResumeStatesByPanelId[panelId] {
            case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning):
                markRestoredAgentCompleted(panelId: panelId, snapshot: restoredAgent)
                restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
                retireAgentHookResumeBinding(panelId: panelId, matching: restoredAgent)
            case .some(.awaitingAutoResumeCommand), .some(.manualResumeAvailable), .some(.completedAgentExit), nil:
                break
            }
        case .unknown:
            break
        }
    }

    func updateBindingOnlyRestoredAgentResumeState(
        panelId: UUID,
        shellState: PanelShellActivityState
    ) {
        switch (shellState, restoredAgentResumeStatesByPanelId[panelId]) {
        case (.commandRunning, .some(.awaitingAutoResumeCommand)):
            restoredAgentResumeStatesByPanelId[panelId] = .autoResumeCommandRunning
        case (.promptIdle, .some(.autoResumeCommandRunning)),
             (.promptIdle, .some(.observedAgentCommandRunning)):
            restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
            restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
            retireAgentHookResumeBinding(panelId: panelId)
        default:
            break
        }
    }

    private func invalidateRestoredAgentSnapshot(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot
    ) {
        let fingerprint = TabManager.restorableAgentSnapshotFingerprint(restoredAgent)
        invalidatedRestoredAgentFingerprintsByPanelId[panelId] = fingerprint
        retireAgentHookResumeBinding(panelId: panelId, matching: restoredAgent)
        clearRestoredAgentSnapshot(panelId: panelId)
#if DEBUG
        cmuxDebugLog(
            "session.restore.agent.invalidate panel=\(panelId.uuidString.prefix(5)) " +
            "kind=\(restoredAgent.kind.rawValue) session=\(restoredAgent.sessionId.prefix(8))"
        )
#endif
    }

    /// Keep the checkpoint available to an explicit `cmux restore`, while
    /// preventing an exited or superseded agent from replaying automatically.
    func retireAgentHookResumeBinding(
        panelId: UUID,
        matching restoredAgent: SessionRestorableAgentSnapshot? = nil
    ) {
        guard var binding = surfaceResumeBindingsByPanelId[panelId],
              binding.isAgentHookBinding else {
            return
        }
        if let restoredAgent,
           let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ManagedAgentSessionIdentity.sessionIDsMatch(
               kind: restoredAgent.kind.rawValue,
               lhs: checkpointId,
               rhs: restoredAgent.sessionId
           ) {
            return
        }
        binding.autoResume = false
        surfaceResumeBindingsByPanelId[panelId] = binding
    }

    /// Keep an in-flight restored launch tied to the same structured binding
    /// so a later, unrelated binding cannot inherit its lifecycle evidence.
    func restoredAgentLifecycleOwns(
        _ binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) -> Bool {
        guard binding.isAgentHookBinding,
              restoredAgentLifecycle.ownsInFlightRestoredCommand(panelId: panelId) else {
            return false
        }
        if let storedBinding = surfaceResumeBindingsByPanelId[panelId] {
            return storedBinding.isSameManagedSession(as: binding)
        }
        guard let restoredAgent = restoredAgentSnapshotsByPanelId[panelId] else {
            return false
        }
        return Self.restorableAgentForSessionRestore(
            restoredAgent,
            resumeBinding: binding
        ) != nil
    }

    /// A real shell callback has advanced this binding's restored launch from
    /// queued input to a running command.
    func restoredAgentLifecycleConfirmsRunning(
        _ binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) -> Bool {
        restoredAgentLifecycle.confirmsRunningRestoredCommand(panelId: panelId) &&
            restoredAgentLifecycleOwns(binding, panelId: panelId)
    }

    /// Preserve restore lifecycle state across a same-session hook refresh,
    /// but never let a replacement binding reuse the prior session's observed
    /// command-running phase.
    func invalidateRestoredAgentLifecycleIfBindingIsReplaced(
        by binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) {
        guard restoredAgentLifecycle.ownsInFlightRestoredCommand(panelId: panelId) else {
            return
        }
        let continuesRestoredSession: Bool
        if let storedBinding = surfaceResumeBindingsByPanelId[panelId] {
            continuesRestoredSession = storedBinding == binding ||
                storedBinding.isSameManagedSession(as: binding)
        } else if let restoredAgent = restoredAgentSnapshotsByPanelId[panelId] {
            continuesRestoredSession = Self.restorableAgentForSessionRestore(
                restoredAgent,
                resumeBinding: binding
            ) != nil
        } else {
            continuesRestoredSession = false
        }
        guard !continuesRestoredSession else { return }
        clearRestoredAgentSnapshot(panelId: panelId)
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
    }

    /// True when `binding` is a plain (non-tmux) agent-hook resume binding
    /// whose session no longer shows up as a live process. Generalizes the
    /// tmux-only `isProcessDetected` staleness signal in
    /// `reconcileSurfaceResumeBindings` so a normal exit of a resumed
    /// non-tmux agent doesn't leave a binding that gets replayed automatically
    /// on the next relaunch (#8446).
    ///
    /// `restorableAgentIndex`, when supplied, is a freshly loaded index from
    /// the same scan generation as the caller's `SurfaceResumeBindingIndex`
    /// (see `ProcessDetectedResumeIndexes.load()`); prefer it over the
    /// separately TTL-cached `SharedLiveAgentIndex.shared.index` so pruning
    /// and the binding scan it is paired with always describe the same
    /// point-in-time snapshot instead of two independently stale ones.
    func isStaleAgentHookBinding(
        _ binding: SurfaceResumeBindingSnapshot,
        panelId: UUID,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil
    ) -> Bool {
        // `RestorableAgentSessionIndex` / `SharedLiveAgentIndex` are built by
        // scanning LOCAL processes (pid/sysctl-based). A `.persistentSSH`
        // agent-hook binding's process runs on the remote host and can never
        // appear in that local scan, so treating it as this function's kind
        // of "stale" would prune every live remote agent-hook binding on the
        // very next reconciliation. Only judge local-launch bindings here;
        // remote bindings are left to whatever governs their own lifecycle.
        guard binding.isAgentHookBinding,
              binding.launchFlavor == .local,
              let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkpointId.isEmpty,
              let kind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kind.isEmpty else {
            return false
        }
        if restoredAgentLifecycleOwns(binding, panelId: panelId) {
            return false
        }
        let liveIndex = restorableAgentIndex ?? SharedLiveAgentIndex.shared.index
        return !AgentResumeLiveness.hasLiveProcess(
            for: liveIndex?.entry(workspaceId: id, panelId: panelId),
            kind: kind,
            sessionId: checkpointId
        )
    }

    func seedSessionRestoredAgentState(
        panelId: UUID,
        restorableAgent: SessionRestorableAgentSnapshot?,
        willRunStartupCommand: Bool,
        willRunStartupInput: Bool
    ) {
        if let restorableAgent {
            restoredAgentSnapshotsByPanelId[panelId] = restorableAgent
        } else {
            restoredAgentSnapshotsByPanelId.removeValue(forKey: panelId)
        }
        if willRunStartupCommand {
            restoredAgentResumeStatesByPanelId[panelId] = .autoResumeCommandRunning
        } else if willRunStartupInput {
            restoredAgentResumeStatesByPanelId[panelId] = .awaitingAutoResumeCommand
        } else if restorableAgent != nil {
            restoredAgentResumeStatesByPanelId[panelId] = .manualResumeAvailable
        } else {
            restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
        }
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
    }

    func seedDetachedRestoredAgentState(from detached: DetachedSurfaceTransfer) {
        if let shellActivityState = detached.shellActivityState {
            panelShellActivityStates[detached.panelId] = shellActivityState
            (detached.panel as? TerminalPanel)?.updateShellActivityState(shellActivityState)
        } else {
            panelShellActivityStates.removeValue(forKey: detached.panelId)
        }
        restoredAgentLifecycle.seedTransferredState(
            panelId: detached.panelId,
            snapshot: detached.restorableAgent,
            resumeState: detached.restorableAgentResumeState,
            completedGeneration: detached.restoredAgentCompletedGeneration
        )
        adoptDetachedAgentLifecycleRecords(
            detached.agentLifecycleRecords,
            panelID: detached.panelId
        )
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: detached.panelId)
    }

    func takeAgentLifecycleRecordsForTransfer(
        panelID: UUID
    ) -> [String: AgentLifecycleRecord] {
        guard let records = agentLifecycleRecordsByPanelId[panelID] else {
            return [:]
        }
        let transferredRecords = records.filter {
            !AgentHibernationLifecycleStatusKeys.isManualKey($0.key)
        }
        let workspaceRecords = records.filter {
            AgentHibernationLifecycleStatusKeys.isManualKey($0.key)
        }
        if workspaceRecords.isEmpty {
            agentLifecycleRecordsByPanelId.removeValue(forKey: panelID)
        } else {
            // The close cleanup that follows a detach removes this panel and
            // rehomes its workspace-scoped manual records onto a surviving
            // source panel. Keeping them here until then prevents a surface
            // transfer from moving workspace loading state to its destination.
            agentLifecycleRecordsByPanelId[panelID] = workspaceRecords
        }
        recordAgentLifecycleChange(panelId: panelID)
        return transferredRecords
    }

    private func adoptDetachedAgentLifecycleRecords(
        _ records: [String: AgentLifecycleRecord],
        panelID: UUID
    ) {
        guard !records.isEmpty else { return }
        agentLifecycleRecordsByPanelId[panelID] = records
        if let maximumRevision = records.values.map(\.revision).max() {
            sidebarAgentRuntimeObservation.reserveAgentLifecycleRevisions(
                after: maximumRevision
            )
        }
        recordAgentLifecycleChange(panelId: panelID)
    }

    @discardableResult
    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState,
        sessionID: String? = nil,
        startsNewOccupant: Bool = false,
        expectedPIDKey: String? = nil,
        expectedPID: Int32? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil,
        requireExistingOwner: Bool = false,
        apply: Bool = true
    ) -> Bool {
        let targetPanelId = panelId ?? focusedPanelId
        guard let targetPanelId, panels[targetPanelId] != nil else { return false }
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
        let normalizedSessionID = normalizedAgentLifecycleSessionID(sessionID)
        let claimedPID: (key: String, pid: Int32)?
        switch (expectedPIDKey, expectedPID) {
        case let (expectedPIDKey?, expectedPID?):
            guard expectedPID > 0,
                  agentStatusKey(forAgentPIDKey: expectedPIDKey) == key else {
                return false
            }
            if expectedProcessIdentity != nil {
                claimedPID = (expectedPIDKey, expectedPID)
            } else if startsNewOccupant,
                      expectedPIDKey == key
                        || normalizedSessionID.map({ expectedPIDKey == "\(key).\($0)" }) == true {
                // SessionStart establishes PID routing and lifecycle ownership
                // in one main-actor commit. Anonymous claims require the exact
                // process generation; durable session identity authorizes the
                // legacy unversioned explicit-session form.
                claimedPID = (expectedPIDKey, expectedPID)
            } else {
                guard agentPIDPanelIdsByKey[expectedPIDKey] == targetPanelId,
                      agentPIDs[expectedPIDKey] == expectedPID else {
                    return false
                }
                claimedPID = nil
            }
        case (nil, nil):
            guard expectedProcessIdentity == nil else { return false }
            claimedPID = nil
        case (nil, _?), (_?, nil):
            return false
        }
        let previous = agentLifecycleRecordsByPanelId[targetPanelId]?[key]
        guard !requireExistingOwner || previous != nil else { return false }
        let hasDifferentAuthoritativeSession = previous?.sessionID != nil
            && normalizedSessionID != nil
            && previous?.sessionID != normalizedSessionID
        // Only a verified session-start hook may rotate an established
        // authoritative occupant. Delayed turn/status hooks from an older
        // session must not reclaim the surface.
        if hasDifferentAuthoritativeSession && !startsNewOccupant {
            return false
        }

        var processGenerationReplacedOccupant = false
        var matchedExistingProcessGeneration = false
        if let claimedPID {
            let outcome = recordAgentPIDOutcome(
                key: claimedPID.key,
                pid: claimedPID.pid,
                panelId: targetPanelId,
                expectedPIDStartSeconds: expectedProcessIdentity?.startSeconds,
                expectedPIDStartMicroseconds: expectedProcessIdentity?.startMicroseconds,
                preservingLifecycleStatusKey: key,
                commit: apply
            )
            guard outcome.accepted else { return false }
            matchedExistingProcessGeneration = outcome.matchedExistingProcessGeneration
            processGenerationReplacedOccupant = previous != nil
                && expectedProcessIdentity != nil
                && !outcome.matchedExistingProcessGeneration
        }
        guard apply else { return true }

        // Session-start hooks may retry. Preserve an established authoritative
        // occupant when either durable session identity or exact anonymous
        // process generation proves it is the same claimant.
        let isDuplicateAuthoritativeStart = startsNewOccupant
            && (
                (normalizedSessionID != nil && previous?.sessionID == normalizedSessionID)
                    || (normalizedSessionID == nil && matchedExistingProcessGeneration)
            )

        let isReplacement = previous != nil
            && (
                hasDifferentAuthoritativeSession
                    || (startsNewOccupant && !isDuplicateAuthoritativeStart)
                    || processGenerationReplacedOccupant
            )

        if let previous, isReplacement {
            publishAgentLifecycleTransition(
                previous,
                state: .exit,
                previousState: previous.publicState,
                panelID: targetPanelId
            )
        }

        var record: AgentLifecycleRecord
        if let previous, !isReplacement {
            record = previous
            record.state = lifecycle
            if record.sessionID == nil {
                record.sessionID = normalizedSessionID
            }
        } else {
            record = AgentLifecycleRecord(
                agent: key,
                state: lifecycle,
                sessionID: normalizedSessionID,
                revision: takeNextAgentLifecycleRevision()
            )
        }
        agentLifecycleRecordsByPanelId[targetPanelId, default: [:]][key] = record

        let isManual = AgentHibernationLifecycleStatusKeys.isManualKey(key)
        if !isManual,
           previous == nil || isReplacement || previous?.state != lifecycle ||
               previous?.sessionID != record.sessionID {
            publishAgentLifecycleTransition(
                record,
                state: record.publicState,
                previousState: isReplacement ? nil : previous?.publicState,
                panelID: targetPanelId
            )
        }
        if !isManual {
            recordAgentLifecycleChange(panelId: targetPanelId)
        }
        return true
    }

    @discardableResult
    func clearAgentLifecycle(
        key: String,
        panelId: UUID? = nil,
        expectedSessionID: String? = nil
    ) -> Bool {
        var didClear = false
        let recordsHibernationActivity = !AgentHibernationLifecycleStatusKeys.isManualKey(key)
        let normalizedExpectedSessionID = normalizedAgentLifecycleSessionID(expectedSessionID)
        let panelIds = panelId.map { [$0] } ?? Array(agentLifecycleRecordsByPanelId.keys)
        for panelId in panelIds {
            guard let record = agentLifecycleRecordsByPanelId[panelId]?[key] else { continue }
            if let normalizedExpectedSessionID,
               record.sessionID != normalizedExpectedSessionID {
                continue
            }
            if recordsHibernationActivity {
                publishAgentLifecycleTransition(
                    record,
                    state: .exit,
                    previousState: record.publicState,
                    panelID: panelId
                )
            }
            agentLifecycleRecordsByPanelId[panelId]?.removeValue(forKey: key)
            if agentLifecycleRecordsByPanelId[panelId]?.isEmpty == true {
                agentLifecycleRecordsByPanelId.removeValue(forKey: panelId)
            }
            didClear = true
            if recordsHibernationActivity {
                recordAgentLifecycleChange(panelId: panelId)
            }
        }
        return didClear
    }

    func hasRunningAgentLifecycle(key: String, panelId: UUID? = nil) -> Bool {
        if let panelId {
            return agentLifecycleRecordsByPanelId[panelId]?[key]?.state == .running
        }
        return agentLifecycleRecordsByPanelId.values.contains { $0[key]?.state == .running }
    }

    func clearAgentLifecycleStates(panelId: UUID) {
        guard let removed = agentLifecycleRecordsByPanelId.removeValue(forKey: panelId) else { return }
        let manualRecords = removed.filter { AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
        for (key, record) in removed where !AgentHibernationLifecycleStatusKeys.isManualKey(key) {
            publishAgentLifecycleTransition(
                record,
                state: .exit,
                previousState: record.publicState,
                panelID: panelId
            )
        }
        if !manualRecords.isEmpty {
            let host: UUID? = if panels[panelId] != nil {
                panelId
            } else if let focused = focusedPanelId, focused != panelId, panels[focused] != nil {
                focused
            } else {
                panels.keys.first(where: { $0 != panelId })
            }
            if let host {
                for (key, record) in manualRecords {
                    agentLifecycleRecordsByPanelId[host, default: [:]][key] = record
                }
            }
        }
        recordAgentLifecycleChange(panelId: panelId)
    }

    func clearAllAgentLifecycleStates() {
        let removed = agentLifecycleRecordsByPanelId
        let panelIds = Array(removed.keys)
        agentLifecycleRecordsByPanelId.removeAll()
        guard !panelIds.isEmpty else { return }
        for (panelID, records) in removed {
            for (key, record) in records where !AgentHibernationLifecycleStatusKeys.isManualKey(key) {
                publishAgentLifecycleTransition(
                    record,
                    state: .exit,
                    previousState: record.publicState,
                    panelID: panelID
                )
            }
        }
        for panelId in panelIds {
            recordAgentLifecycleChange(panelId: panelId)
        }
    }

    func agentHibernationLifecycleState(
        panelId: UUID,
        fallback: AgentHibernationLifecycleState?
    ) -> AgentHibernationLifecycleState {
        let states = (agentLifecycleRecordsByPanelId[panelId] ?? [:])
            .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
            .map(\.value.state)
        guard !states.isEmpty else {
            return fallback ?? .unknown
        }
        if states.contains(.running) { return .running }
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.unknown) { return .unknown }
        if states.contains(.idle) { return .idle }
        return fallback ?? .unknown
    }

    func agentWaitSurfaceSnapshot(surfaceID: UUID) -> AgentWaitSurfaceSnapshot? {
        guard let ownership = surfaceOwnershipTarget(for: surfaceID) else { return nil }
        let lifecyclePanelID = ownership.containerPanelID
        let occupants = agentLifecycleRecordsByPanelId[lifecyclePanelID]?
            .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
            .map(\.value)
            ?? []
        let occupant = occupants.count == 1 ? occupants[0] : nil
        return AgentWaitSurfaceSnapshot(
            workspaceID: id,
            surfaceID: lifecyclePanelID,
            paneID: paneId(forPanelId: lifecyclePanelID)?.id,
            occupant: occupant
        )
    }

    private func publishAgentLifecycleTransition(
        _ record: AgentLifecycleRecord,
        state: AgentLifecyclePublicState,
        previousState: AgentLifecyclePublicState?,
        panelID: UUID
    ) {
        CmuxEventBus.shared.publishAgentStateChanged(
            workspaceID: id,
            surfaceID: panelID,
            paneID: paneId(forPanelId: panelID)?.id,
            record: record,
            state: state,
            previousState: previousState
        )
    }

    private func normalizedAgentLifecycleSessionID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func recordAgentLifecycleChange(panelId: UUID) {
        AgentHibernationController.shared.recordAgentLifecycleChange(
            workspaceId: id,
            panelId: panelId
        )
    }
}
