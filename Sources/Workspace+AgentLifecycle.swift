import CMUXAgentLaunch
import CmuxWorkspaces
import Foundation

extension Workspace {
    enum LegacyHermesSessionResolution {
        case valid
        case legacyRestore(SessionRestorableAgentSnapshot)
        case recovered(SessionRestorableAgentSnapshot)
        case missing
        case unavailable
    }

    typealias LegacyHermesSessionRecovery = (
        _ workspaceId: UUID?,
        _ surfaceId: UUID,
        _ corruptSessionId: String
    ) -> SessionRestorableAgentSnapshot?

    /// Repairs transient Hermes TUI identities before restore policy evaluates
    /// `wasAgentRunning` or binding compatibility.
    ///
    /// A failed launch is immediately re-saved as not running, so waiting until
    /// `cmux restore` executes leaves the pane permanently unable to reach the
    /// CLI's record repair on later launches. Workspace and dock restore both
    /// call this shared projection before making any launch decision.
    nonisolated static func repairedLegacyHermesSessionPanelSnapshot(
        _ snapshot: SessionPanelSnapshot,
        workspaceId: UUID?
    ) -> SessionPanelSnapshot {
        let environment = legacyHermesRecoveryEnvironment(for: snapshot)
        let terminal = snapshot.terminal
        let sourceBinding = terminal?.resumeBinding ?? terminal?.managedAgentResumeBinding
        let expectedWorkingDirectory = terminal?.agent?.workingDirectory
            ?? sourceBinding?.cwd
            ?? terminal?.workingDirectory
        return repairedLegacyHermesSessionPanelSnapshot(
            snapshot,
            workspaceId: workspaceId,
            resolve: { workspaceId, surfaceId, corruptSessionId in
                resolveLegacyHermesSession(
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    corruptSessionId: corruptSessionId,
                    expectedWorkingDirectory: expectedWorkingDirectory,
                    environment: environment
                )
            }
        )
    }

    nonisolated static func repairedLegacyHermesSessionPanelSnapshot(
        _ snapshot: SessionPanelSnapshot,
        workspaceId: UUID?,
        recover: LegacyHermesSessionRecovery
    ) -> SessionPanelSnapshot {
        repairedLegacyHermesSessionPanelSnapshot(
            snapshot,
            workspaceId: workspaceId,
            resolve: { workspaceId, surfaceId, corruptSessionId in
                recover(workspaceId, surfaceId, corruptSessionId)
                    .map(LegacyHermesSessionResolution.recovered)
                    ?? .missing
            }
        )
    }

    private nonisolated static func repairedLegacyHermesSessionPanelSnapshot(
        _ snapshot: SessionPanelSnapshot,
        workspaceId: UUID?,
        resolve: (
            _ workspaceId: UUID?,
            _ surfaceId: UUID,
            _ corruptSessionId: String
        ) -> LegacyHermesSessionResolution
    ) -> SessionPanelSnapshot {
        guard var terminal = snapshot.terminal,
              let sourceBinding = terminal.resumeBinding ?? terminal.managedAgentResumeBinding,
              sourceBinding.isAgentHookBinding,
              sourceBinding.kind == RestorableAgentKind.hermesAgent.rawValue,
              let corruptSessionId = sourceBinding.checkpointId?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !corruptSessionId.isEmpty else {
            return snapshot
        }

        func rearmedSnapshot(
            recoveredAgent incomingAgent: SessionRestorableAgentSnapshot,
            requiresIdentityChange: Bool
        ) -> SessionPanelSnapshot {
            var recoveredAgent = incomingAgent
            guard recoveredAgent.kind == .hermesAgent else { return snapshot }
            let identityChanged = recoveredAgent.sessionId
                .caseInsensitiveCompare(corruptSessionId) != .orderedSame
            guard identityChanged == requiresIdentityChange else { return snapshot }

            let existingAgent = terminal.agent
            recoveredAgent.workingDirectory = existingAgent?.workingDirectory
                ?? sourceBinding.cwd
                ?? terminal.workingDirectory
            recoveredAgent.launchCommand = recoveredAgent.launchCommand
                ?? existingAgent?.launchCommand
                ?? sourceBinding.launchCommand
            recoveredAgent.registration = existingAgent?.registration
                ?? CmuxVaultAgentRegistration.builtInHermes
            recoveredAgent.permissionMode = existingAgent?.permissionMode

            var repairedBinding = sourceBinding
            repairedBinding.checkpointId = recoveredAgent.sessionId
            repairedBinding.launchCommand = recoveredAgent.launchCommand
                ?? repairedBinding.launchCommand
            repairedBinding.cwd = recoveredAgent.workingDirectory ?? repairedBinding.cwd
            if let command = recoveredAgent.resumeCommand {
                repairedBinding.command = command
            }
            repairedBinding.autoResume = true

            terminal.agent = recoveredAgent
            terminal.resumeBinding = repairedBinding
            terminal.managedAgentResumeBinding = repairedBinding.hasCompleteManagedSessionIdentity
                ? repairedBinding
                : nil
            // Running hook evidence is authoritative for this one-time migration
            // rescue. Once the repaired agent launches, normal lifecycle capture
            // retires completed sessions and keeps them idle on later restores.
            terminal.wasAgentRunning = true

            var repaired = snapshot
            repaired.terminal = terminal
#if DEBUG
            let event = requiresIdentityChange
                ? "session.restore.hermesIdentityRepair"
                : "session.restore.hermesLegacyRestoreRearmed"
            cmuxDebugLog(
                "\(event) panel=\(snapshot.id.uuidString.prefix(5)) " +
                    "session=\(recoveredAgent.sessionId.prefix(12))"
            )
#endif
            return repaired
        }

        let resolution = resolve(workspaceId, snapshot.id, corruptSessionId)
        switch resolution {
        case .valid, .unavailable:
            return snapshot
        case .missing:
            func removingMissingBinding(
                _ binding: SurfaceResumeBindingSnapshot?
            ) -> SurfaceResumeBindingSnapshot? {
                guard let binding,
                      binding.isAgentHookBinding,
                      binding.kind == RestorableAgentKind.hermesAgent.rawValue,
                      binding.checkpointId?.caseInsensitiveCompare(corruptSessionId) == .orderedSame else {
                    return binding
                }
                return nil
            }

            if terminal.agent?.kind == .hermesAgent,
               terminal.agent?.sessionId.caseInsensitiveCompare(corruptSessionId) == .orderedSame {
                terminal.agent = nil
            }
            terminal.resumeBinding = removingMissingBinding(terminal.resumeBinding)
            terminal.managedAgentResumeBinding = removingMissingBinding(
                terminal.managedAgentResumeBinding
            )
            terminal.wasAgentRunning = false

            var repaired = snapshot
            repaired.terminal = terminal
#if DEBUG
            cmuxDebugLog(
                "session.restore.hermesMissingCheckpoint panel=\(snapshot.id.uuidString.prefix(5)) " +
                    "session=\(corruptSessionId.prefix(12))"
            )
#endif
            return repaired
        case .legacyRestore(let recoveredAgent):
            return rearmedSnapshot(
                recoveredAgent: recoveredAgent,
                requiresIdentityChange: false
            )
        case .recovered(let recoveredAgent):
            return rearmedSnapshot(
                recoveredAgent: recoveredAgent,
                requiresIdentityChange: true
            )
        }
    }

    private nonisolated static func resolveLegacyHermesSession(
        workspaceId: UUID?,
        surfaceId: UUID,
        corruptSessionId: String,
        expectedWorkingDirectory: String?,
        environment: [String: String]
    ) -> LegacyHermesSessionResolution {
        let hookStateFileURL = RestorableAgentKind.hermesAgent.hookStoreFileURL(
            homeDirectory: NSHomeDirectory(),
            environment: environment
        )
        switch HermesLegacySessionIdentityRecovery().resolve(
            surfaceID: surfaceId,
            corruptSessionID: corruptSessionId,
            expectedWorkspaceID: workspaceId,
            expectedWorkingDirectory: expectedWorkingDirectory,
            hookStateFileURL: hookStateFileURL,
            environment: environment
        ) {
        case .valid:
            return .valid
        case .legacyRestore(let recovered):
            return .legacyRestore(SessionRestorableAgentSnapshot(
                kind: .hermesAgent,
                sessionId: recovered.sessionID,
                workingDirectory: nil,
                launchCommand: recovered.launchCommand,
                registration: CmuxVaultAgentRegistration.builtInHermes
            ))
        case .missing:
            return .missing
        case .unavailable:
            return .unavailable
        case .recovered(let recovered):
            return .recovered(SessionRestorableAgentSnapshot(
                kind: .hermesAgent,
                sessionId: recovered.sessionID,
                workingDirectory: nil,
                launchCommand: recovered.launchCommand,
                registration: CmuxVaultAgentRegistration.builtInHermes
            ))
        }
    }

    private nonisolated static func legacyHermesRecoveryEnvironment(
        for snapshot: SessionPanelSnapshot
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let terminal = snapshot.terminal
        let sourceBinding = terminal?.resumeBinding ?? terminal?.managedAgentResumeBinding
        let launchCommands = [
            terminal?.agent?.launchCommand,
            sourceBinding?.launchCommand,
        ]
        for launchCommand in launchCommands {
            if let captured = launchCommand?.environment {
                environment.merge(captured) { _, incoming in incoming }
            }
        }
        return environment
    }

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
                restoredAgentLifecycle.setResumeState(.autoResumeCommandRunning, panelId: panelId)
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
            restoredAgentLifecycle.setResumeState(.autoResumeCommandRunning, panelId: panelId)
        case (.promptIdle, .some(.autoResumeCommandRunning)),
             (.promptIdle, .some(.observedAgentCommandRunning)):
            restoredAgentLifecycle.setResumeState(nil, panelId: panelId)
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
        let liveEntry = liveIndex?.entry(workspaceId: id, panelId: panelId)
        if liveIndex?.hasAmbiguousPanel(panelId) == true, liveEntry == nil {
            return false
        }
        return !AgentResumeLiveness.hasLiveProcess(
            for: liveEntry,
            kind: kind,
            sessionId: checkpointId
        )
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
            completedGeneration: detached.restoredAgentCompletedGeneration,
            resumeWorkingDirectory: detached.restoredResumeSessionWorkingDirectory
        )
        if let deferredRestore = detached.deferredAgentResumeRestore {
            deferAgentResumeRestore(
                panelId: detached.panelId,
                restore: deferredRestore
            )
        }
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: detached.panelId)
    }

    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState
    ) {
        let targetPanelId = panelId ?? focusedPanelId
        guard let targetPanelId, panels[targetPanelId] != nil else { return }
        agentLifecycleStatesByPanelId[targetPanelId, default: [:]][key] = lifecycle
        if !AgentHibernationLifecycleStatusKeys.isManualKey(key) {
            recordAgentLifecycleChange(panelId: targetPanelId)
        }
    }

    @discardableResult
    func clearAgentLifecycle(key: String, panelId: UUID? = nil) -> Bool {
        var didClear = false
        let recordsHibernationActivity = !AgentHibernationLifecycleStatusKeys.isManualKey(key)
        let panelIds = panelId.map { [$0] } ?? Array(agentLifecycleStatesByPanelId.keys)
        for panelId in panelIds {
            guard agentLifecycleStatesByPanelId[panelId]?[key] != nil else { continue }
            agentLifecycleStatesByPanelId[panelId]?.removeValue(forKey: key)
            if agentLifecycleStatesByPanelId[panelId]?.isEmpty == true {
                agentLifecycleStatesByPanelId.removeValue(forKey: panelId)
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
            return agentLifecycleStatesByPanelId[panelId]?[key] == .running
        }
        return agentLifecycleStatesByPanelId.values.contains { $0[key] == .running }
    }

    func clearAgentLifecycleStates(panelId: UUID) {
        guard let removed = agentLifecycleStatesByPanelId.removeValue(forKey: panelId) else { return }
        let manualStates = removed.filter { AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
        if !manualStates.isEmpty {
            let host: UUID? = if panels[panelId] != nil {
                panelId
            } else if let focused = focusedPanelId, focused != panelId, panels[focused] != nil {
                focused
            } else {
                panels.keys.first(where: { $0 != panelId })
            }
            if let host {
                for (key, lifecycle) in manualStates {
                    agentLifecycleStatesByPanelId[host, default: [:]][key] = lifecycle
                }
            }
        }
        recordAgentLifecycleChange(panelId: panelId)
    }

    func clearAllAgentLifecycleStates() {
        let panelIds = Array(agentLifecycleStatesByPanelId.keys)
        guard !panelIds.isEmpty else { return }
        agentLifecycleStatesByPanelId.removeAll()
        for panelId in panelIds {
            recordAgentLifecycleChange(panelId: panelId)
        }
    }

    /// Defers one restore launch until the off-main shared agent index is ready.
    ///
    /// Restore is synchronous because it rebuilds Bonsplit topology, while the
    /// live-agent index is intentionally asynchronous. Keeping the request on
    /// the owner lets the terminal join its topology first and avoids a main
    /// actor hook-store scan.
    func deferAgentResumeRestore(
        panelId: UUID,
        restore: DeferredAgentResumeRestore
    ) {
        deferredAgentResumeRestoresByPanelId[panelId] = restore
        guard deferredAgentResumeIndexTask == nil else { return }
        deferredAgentResumeIndexTask = Task { @MainActor [weak self] in
            let index = await SharedLiveAgentIndex.shared.indexRefreshingNow()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.deferredAgentResumeIndexTask = nil
            guard let index else {
                self.clearDeferredAgentResumeRestores()
                return
            }
            self.resolveDeferredAgentResumeRestores(using: index)
        }
    }

    private func resolveDeferredAgentResumeRestores(
        using index: RestorableAgentSessionIndex
    ) {
        let policy = Self.makeSessionRestorePolicyService()
        for (panelId, restore) in Array(deferredAgentResumeRestoresByPanelId) {
            // Explicit input can cancel the staged record while this snapshot
            // is being iterated. Never resurrect a cancelled command.
            guard deferredAgentResumeRestoresByPanelId[panelId] != nil else {
                continue
            }
            guard let terminal = panels[panelId] as? TerminalPanel else {
                removeDeferredAgentResumeRestore(panelId: panelId)
                continue
            }
            guard AgentSessionAutoResumeSettings.isEnabled(
                defaults: agentSessionAutoResumeDefaults
            ) else {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            guard index.isComplete else {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            guard deferredAgentResumeRestoreMatchesCurrentSession(
                panelId: panelId,
                restore: restore
            ) else {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            let ownershipPanelID = restore.stablePanelID
            let expectedKind = restore.restorableAgent?.kind.rawValue ?? restore.resumeBinding?.kind
            let expectedSessionId = restore.restorableAgent?.sessionId ?? restore.resumeBinding?.checkpointId
            // Deferred admission has no exact-owner snapshot that can override a
            // stable-panel tie, so structural ambiguity remains fail-closed even
            // after the old owners' PIDs have exited.
            let ownershipIsBlocked = index.hasAmbiguousPanel(ownershipPanelID) ||
                index.hasCurrentAmbiguousPanel(
                    ownershipPanelID,
                    revalidateProcessEvidence: false
                ) ||
                index.hasUncertainStablePanelEntry(
                    panelId: ownershipPanelID,
                    revalidateProcessEvidence: false
                ) ||
                index.hasConflictingLiveStablePanelEntry(
                    workspaceId: id,
                    panelId: ownershipPanelID,
                    expectedKind: expectedKind,
                    expectedSessionId: expectedSessionId,
                    revalidateProcessEvidence: false
                ) ||
                index.hasCurrentLiveProcessForStablePanel(
                    workspaceId: id,
                    panelId: ownershipPanelID,
                    revalidateProcessEvidence: false
                )
            guard !ownershipIsBlocked else {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }

            let startupInput: String?
            let claim: (kind: String, sessionId: String)?
            if let restorableAgent = restore.restorableAgent {
                startupInput = if restore.restoresRemoteWorkspaceTerminalSnapshot {
                    restorableAgent.resumeStartupInput(
                        useLocalRestoreVerb: false,
                        restoringWorkingDirectory: restore.resumeWorkingDirectory
                    )
                } else {
                    restorableAgent.resumeStartupInput(
                        restoringWorkingDirectory: restore.resumeWorkingDirectory
                    )
                }
                claim = (restorableAgent.kind.rawValue, restorableAgent.sessionId)
            } else if let binding = restore.resumeBinding {
                let approvedBinding = policy.approvedSurfaceResumeBinding(
                    binding,
                    autoResumeAgentSessions: AgentSessionAutoResumeSettings.isEnabled(
                        defaults: agentSessionAutoResumeDefaults
                    ),
                    promptForApproval: true,
                    approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
                )
                startupInput = approvedBinding.flatMap {
                    policy.surfaceResumeStartupLaunch(forApprovedBinding: $0)?.initialInput
                }
                claim = binding.kind.flatMap { kind in
                    binding.checkpointId.map { (kind, $0) }
                }
            } else {
                startupInput = nil
                claim = nil
            }
            guard let startupInput, !startupInput.isEmpty else {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            if let claim,
               !AgentResumeLaunchGuard.shared.claimResumeLaunch(
                   kind: claim.kind,
                   sessionId: claim.sessionId
               ) {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            if let claim {
                deferredAgentResumeClaimsByPanelId[panelId] = claim
            }
            if let restoreWorkingDirectory = restore.resumeWorkingDirectory {
                restoredResumeSessionWorkingDirectoriesByPanelId[panelId] = restoreWorkingDirectory
            }
            restoredAgentLifecycle.setResumeState(
                .awaitingAutoResumeCommand,
                panelId: panelId
            )
            let admitted = terminal.surface.admitStartupRestoreRuntime(
                initialInput: startupInput
            )
            if !admitted {
                if let claim {
                    AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                        kind: claim.kind,
                        sessionId: claim.sessionId
                    )
                }
                deferredAgentResumeClaimsByPanelId.removeValue(forKey: panelId)
                restoredAgentLifecycle.setResumeState(
                    restore.restorableAgent == nil ? nil : .manualResumeAvailable,
                    panelId: panelId
                )
            } else {
                terminalStartupRestoreCoordinator.recordDeferredResumeIntent(
                    panelID: panelId,
                    snapshot: restore.restorableAgent,
                    resumeBinding: restore.resumeBinding,
                    workingDirectory: restore.resumeWorkingDirectory ?? restore.workingDirectory
                )
                deferredAgentResumeRestoresByPanelId.removeValue(forKey: panelId)
                if let claim,
                   let pendingClaim = deferredAgentResumeClaimsByPanelId[panelId],
                   pendingClaim.kind == claim.kind,
                   pendingClaim.sessionId == claim.sessionId {
                    // After admission the guard's bounded TTL owns this claim;
                    // do not let later panel teardown release a newer claimant.
                    deferredAgentResumeClaimsByPanelId.removeValue(forKey: panelId)
                }
            }
        }
    }

    func removeDeferredAgentResumeRestore(panelId: UUID) {
        deferredAgentResumeRestoresByPanelId.removeValue(forKey: panelId)
        if let claim = deferredAgentResumeClaimsByPanelId.removeValue(forKey: panelId) {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: claim.kind,
                sessionId: claim.sessionId
            )
        }
    }

    func cancelDeferredAgentResumeRestore(
        panelId: UUID,
        restore: DeferredAgentResumeRestore
    ) {
        (panels[panelId] as? TerminalPanel)?.surface.cancelStartupRestoreAdmission()
        removeDeferredAgentResumeRestore(panelId: panelId)
        if restore.restorableAgent == nil {
            if let binding = restore.resumeBinding {
                retireAgentHookResumeBinding(panelId: panelId, matching: binding)
            }
        }
        restoredAgentLifecycle.setResumeState(.manualResumeAvailable, panelId: panelId)
    }

    private func deferredAgentResumeRestoreMatchesCurrentSession(
        panelId: UUID,
        restore: DeferredAgentResumeRestore
    ) -> Bool {
        guard let currentRestore = deferredAgentResumeRestoresByPanelId[panelId],
              currentRestore.stablePanelID == restore.stablePanelID,
              let expectedKind = restore.restorableAgent?.kind.rawValue ?? restore.resumeBinding?.kind,
              let expectedSessionID = restore.restorableAgent?.sessionId ?? restore.resumeBinding?.checkpointId else {
            return false
        }
        let currentSnapshot = restoredAgentLifecycle.snapshotsByPanelId[panelId]
            ?? terminalStartupRestoreCoordinator.stagedSnapshot(panelID: panelId)
        if let currentSnapshot {
            guard currentSnapshot.kind.rawValue == expectedKind,
                  ManagedAgentSessionIdentity.sessionIDsMatch(
                      kind: expectedKind,
                      lhs: currentSnapshot.sessionId,
                      rhs: expectedSessionID
                  ) else {
                return false
            }
        } else if restore.restorableAgent != nil {
            return false
        }

        if restore.resumeBinding != nil {
            guard let currentBinding = surfaceResumeBindingsByPanelId[panelId],
                  let currentKind = currentBinding.kind,
                  let currentSessionID = currentBinding.checkpointId,
                  currentKind == expectedKind,
                  ManagedAgentSessionIdentity.sessionIDsMatch(
                      kind: expectedKind,
                      lhs: currentSessionID,
                      rhs: expectedSessionID
                  ) else {
                return false
            }
        } else if let currentBinding = surfaceResumeBindingsByPanelId[panelId] {
            guard let currentKind = currentBinding.kind,
                  let currentSessionID = currentBinding.checkpointId,
                  currentKind == expectedKind,
                  ManagedAgentSessionIdentity.sessionIDsMatch(
                      kind: expectedKind,
                      lhs: currentSessionID,
                      rhs: expectedSessionID
                  ) else {
                return false
            }
        }
        return true
    }

    private func retireAgentHookResumeBinding(
        panelId: UUID,
        matching binding: SurfaceResumeBindingSnapshot
    ) {
        guard let currentBinding = surfaceResumeBindingsByPanelId[panelId],
              currentBinding.isAgentHookBinding,
              currentBinding == binding || currentBinding.isSameManagedSession(as: binding) else {
            return
        }
        retireAgentHookResumeBinding(panelId: panelId)
    }

    func clearDeferredAgentResumeRestores() {
        deferredAgentResumeIndexTask?.cancel()
        deferredAgentResumeIndexTask = nil
        let panelIds = Set(
            Array(deferredAgentResumeRestoresByPanelId.keys)
                + Array(deferredAgentResumeClaimsByPanelId.keys)
        )
        for panelId in panelIds {
            if let restore = deferredAgentResumeRestoresByPanelId[panelId] {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
            } else {
                (panels[panelId] as? TerminalPanel)?.surface.cancelStartupRestoreAdmission()
                removeDeferredAgentResumeRestore(panelId: panelId)
            }
        }
        deferredAgentResumeRestoresByPanelId.removeAll()
    }

    func agentHibernationLifecycleState(
        panelId: UUID,
        fallback: AgentHibernationLifecycleState?
    ) -> AgentHibernationLifecycleState {
        let states = (agentLifecycleStatesByPanelId[panelId] ?? [:])
            .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
            .map(\.value)
        guard !states.isEmpty else {
            return fallback ?? .unknown
        }
        if states.contains(.running) { return .running }
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.unknown) { return .unknown }
        if states.contains(.idle) { return .idle }
        return fallback ?? .unknown
    }

    private func recordAgentLifecycleChange(panelId: UUID) {
        AgentHibernationController.shared.recordAgentLifecycleChange(
            workspaceId: id,
            panelId: panelId
        )
    }
}
