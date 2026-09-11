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
                restoredAgentLifecycle.clearStartupInput(panelId: panelId)
            case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning),
                 .some(.completedAgentExit):
                break
            case .some(.manualResumeAvailable), nil:
                if restoredAgentHasLiveProcess(restoredAgent, panelId: panelId) {
                    // A TUI turn (OSC 133;C) from the agent itself, not an
                    // unrelated command replacing an idle agent.
                    restoredAgentLifecycle.setResumeState(.observedAgentCommandRunning, panelId: panelId)
                } else {
                    invalidateRestoredAgentSnapshot(panelId: panelId, restoredAgent: restoredAgent)
                }
            }
        case .promptIdle:
            switch restoredAgentResumeStatesByPanelId[panelId] {
            case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning):
                // A TUI prompt mark (OSC 133;A) is not the shell prompt
                // returning while the agent process is still alive.
                guard !restoredAgentHasLiveProcess(restoredAgent, panelId: panelId) else { break }
                markRestoredAgentCompleted(panelId: panelId, snapshot: restoredAgent)
                restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
                retireAgentHookResumeBinding(panelId: panelId, matching: restoredAgent)
            case .some(.awaitingAutoResumeCommand):
                scheduleRestoredStartupInputResend(panelId: panelId)
            case .some(.manualResumeAvailable), .some(.completedAgentExit), nil:
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
            restoredAgentLifecycle.clearStartupInput(panelId: panelId)
        case (.promptIdle, .some(.awaitingAutoResumeCommand)):
            scheduleRestoredStartupInputResend(panelId: panelId)
        case (.promptIdle, .some(.autoResumeCommandRunning)),
             (.promptIdle, .some(.observedAgentCommandRunning)):
            guard !agentHookBindingHasLiveProcess(panelId: panelId) else { break }
            restoredAgentLifecycle.setResumeState(nil, panelId: panelId)
            restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
            retireAgentHookResumeBinding(panelId: panelId)
        default:
            break
        }
    }

    /// Grace period between a restored launch's shell settling at an idle prompt
    /// and replaying its startup input. Long enough for a prompt-then-command
    /// sequence to report `commandRunning`, short enough that a lost restore
    /// still resumes before the user notices an empty shell.
    static var restoredStartupInputResendGrace: TimeInterval = 2

    /// Replays a retained restore selector once after the shell reports an idle prompt.
    func scheduleRestoredStartupInputResend(panelId: UUID) {
        guard restoredAgentLifecycle.armStartupInputResend(panelId: panelId) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoredStartupInputResendGrace) { [weak self] in
            Task { @MainActor [weak self] in
                self?.resendRestoredStartupInputIfStillIdle(panelId: panelId)
            }
        }
    }

    func resendRestoredStartupInputIfStillIdle(panelId: UUID) {
        let shellState = panelShellActivityStates[panelId] ?? .unknown
        guard !isRetiredFromOwningTabManager,
              let terminal = panels[panelId] as? TerminalPanel,
              let input = restoredAgentLifecycle.takeStartupInputForResend(panelId: panelId, shellState: shellState),
              terminal.surface.surface != nil else { return }
        _ = terminal.sendInputResult(input)
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
        if surfaceResumeBindingMutationAllowed(binding, panelId: panelId) {
            surfaceResumeBindingsByPanelId[panelId] = binding
        }
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
            resumeWorkingDirectory: detached.restoredResumeSessionWorkingDirectory,
            startupInput: detached.restoredStartupInput
        )
        if detached.shellActivityState == .promptIdle {
            scheduleRestoredStartupInputResend(panelId: detached.panelId)
        }
        if let deferredRestore = detached.deferredAgentResumeRestore {
            let adoptedRemoteContext = surfaceResumeBindingsByPanelId[detached.panelId]?
                .launchFlavor.remoteContext
            deferAgentResumeRestore(
                panelId: detached.panelId,
                restore: deferredRestore.retargetingRemoteOwner(adoptedRemoteContext)
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
            let outcome = await SharedLiveAgentIndex.shared.indexForOwnershipDecision()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.deferredAgentResumeIndexTask = nil
            switch outcome {
            case .index(let index):
                self.resolveDeferredAgentResumeRestores(using: index)
            case .timedOut:
                self.explainUnverifiableDeferredAgentResumeRestores()
            case .cancelled:
                self.clearDeferredAgentResumeRestores()
            }
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
            let expectedKind = restore.restorableAgent?.kind.rawValue ?? restore.resumeBinding?.kind
            guard index.isComplete(
                forPanelId: restore.stablePanelID,
                kind: expectedKind
            ) else {
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
            let currentResumeBinding: SurfaceResumeBindingSnapshot?
            if let capturedBinding = restore.resumeBinding {
                guard let currentBinding = surfaceResumeBindingsByPanelId[panelId],
                      currentBinding.isAgentHookBinding,
                      currentBinding.isSameManagedSession(as: capturedBinding),
                      currentBinding.autoResume == true else {
                    cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                    continue
                }
                currentResumeBinding = currentBinding
            } else {
                currentResumeBinding = nil
            }
            if restore.remoteResumeCommandEmbedded {
                // The attach command was embedded in the terminal's initial
                // command before the ownership scan. Require the complete
                // managed binding to remain unchanged (including its command,
                // cwd, and launch flavor) so a changed resume payload can
                // never execute from the stale terminal configuration.
                guard let capturedBinding = restore.resumeBinding,
                      let currentResumeBinding,
                      capturedBinding == currentResumeBinding else {
                    cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                    continue
                }
            }
            let ownershipPanelID = restore.stablePanelID
            let expectedSessionId = restore.restorableAgent?.sessionId ?? restore.resumeBinding?.checkpointId
            let liveSessionOwner: LiveAgentSessionOwner? = if let expectedKind,
                let expectedSessionId {
                index.liveSessionOwner(
                    kind: expectedKind,
                    sessionID: expectedSessionId,
                    revalidateProcessEvidence: true
                )
            } else {
                nil
            }
            if let liveSessionOwner {
                explainDeferredAgentResumeRestore(
                    panelId: panelId,
                    restore: restore,
                    terminal: terminal,
                    noticeInput: AgentRestoreLiveOwnerNotice(
                        processID: liveSessionOwner.processID
            ).startupInput(dialect: restore.noticeDialect)
                )
                AgentRestoreSuppressionJournal().record(
                    kind: liveSessionOwner.kind,
                    sessionID: liveSessionOwner.sessionID,
                    workspaceID: id,
                    surfaceID: panelId,
                    processID: liveSessionOwner.processID
                )
                continue
            }
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
            } else if let binding = currentResumeBinding ?? restore.resumeBinding {
                if restore.restoresRemoteWorkspaceTerminalSnapshot {
                    guard binding.launchFlavor.remoteContext == restore.remoteResumeContext else {
                        cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                        continue
                    }
                }
                let approvedBinding = policy.approvedSurfaceResumeBinding(
                    binding,
                    autoResumeAgentSessions: AgentSessionAutoResumeSettings.isEnabled(
                        defaults: agentSessionAutoResumeDefaults
                    ),
                    promptForApproval: true,
                    approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
                )
                startupInput = approvedBinding.flatMap {
                    if restore.restoresRemoteWorkspaceTerminalSnapshot {
                        return $0.remoteStartupInput()
                    }
                    return policy.surfaceResumeStartupLaunch(forApprovedBinding: $0)?.initialInput
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
            let ownedClaim = restore.restoresRemoteWorkspaceTerminalSnapshot
                ? claim
                : nil
            if let ownedClaim,
               !AgentResumeLaunchGuard.shared.claimResumeLaunch(
                   kind: ownedClaim.kind,
                   sessionId: ownedClaim.sessionId
               ) {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            if let ownedClaim {
                deferredAgentResumeClaimsByPanelId[panelId] = ownedClaim
            }
            if let restoreWorkingDirectory = restore.resumeWorkingDirectory {
                restoredResumeSessionWorkingDirectoriesByPanelId[panelId] = restoreWorkingDirectory
            }
            restoredAgentLifecycle.setResumeState(
                .awaitingAutoResumeCommand,
                panelId: panelId
            )
            let admittedInput = restore.remoteResumeCommandEmbedded ? nil : startupInput
            restoredAgentLifecycle.registerStartupInput(admittedInput, panelId: panelId)
            let admitted = terminal.surface.admitStartupRestoreRuntime(
                initialInput: admittedInput
            )
            if !admitted {
                restoredAgentLifecycle.clearStartupInput(panelId: panelId)
                if let ownedClaim {
                    AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                        kind: ownedClaim.kind,
                        sessionId: ownedClaim.sessionId
                    )
                }
                deferredAgentResumeClaimsByPanelId.removeValue(forKey: panelId)
                deferredAgentResumeRestoresByPanelId.removeValue(forKey: panelId)
                restoredAgentLifecycle.setResumeState(
                    restore.restorableAgent == nil ? nil : .manualResumeAvailable,
                    panelId: panelId
                )
            } else {
                terminalStartupRestoreCoordinator.recordDeferredResumeIntent(
                    panelID: panelId,
                    snapshot: restore.restorableAgent,
                    resumeBinding: currentResumeBinding ?? restore.resumeBinding,
                    workingDirectory: restore.resumeWorkingDirectory ?? restore.workingDirectory
                )
                deferredAgentResumeRestoresByPanelId.removeValue(forKey: panelId)
                if let ownedClaim,
                   let pendingClaim = deferredAgentResumeClaimsByPanelId[panelId],
                   pendingClaim.kind == ownedClaim.kind,
                   pendingClaim.sessionId == ownedClaim.sessionId {
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
        restore: DeferredAgentResumeRestore,
        startRuntime: Bool = true,
        retireBinding: Bool = true
    ) {
        if startRuntime {
            (panels[panelId] as? TerminalPanel)?.surface.cancelStartupRestoreAdmission()
        } else {
            terminalStartupRestoreCoordinator.discardPendingRestoreForPanelTeardown(panelID: panelId)
            restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
        }
        removeDeferredAgentResumeRestore(panelId: panelId)
        restoredAgentLifecycle.clearStartupInput(panelId: panelId)
        if startRuntime, retireBinding, restore.restorableAgent == nil {
            if let binding = restore.resumeBinding {
                retireAgentHookResumeBinding(panelId: panelId, matching: binding)
            }
        }
        if startRuntime {
            restoredAgentLifecycle.setResumeState(.manualResumeAvailable, panelId: panelId)
        }
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

    /// Replaces a deferred automatic resume with a typed explanation, so the
    /// pane says why nothing was resumed and how to resume it by hand.
    private func explainDeferredAgentResumeRestore(
        panelId: UUID,
        restore: DeferredAgentResumeRestore,
        terminal: TerminalPanel,
        noticeInput: String
    ) {
        removeDeferredAgentResumeRestore(panelId: panelId)
        restoredAgentLifecycle.setResumeState(
            .manualResumeAvailable,
            panelId: panelId
        )
        if restore.remoteResumeCommandEmbedded {
            let fallbackCommand: String
            if let remoteResumeContext = restore.remoteResumeContext,
               let remoteNoticeCommand = persistentSSHLiveOwnerNoticeCommand(noticeInput) {
                fallbackCommand = remotePTYAttachStartupCommand(
                    sessionID: remoteResumeContext.persistentPTYSessionID,
                    remoteCommand: remoteNoticeCommand
                )
            } else {
                fallbackCommand = noticeInput
            }
            terminal.surface.setStartupRestoreAdmissionFallbackCommand(fallbackCommand)
            // The original remote attach command contains the agent resume
            // payload. Cancel admission so the attach-only/notice fallback
            // replaces it and the payload can never execute.
            terminal.surface.cancelStartupRestoreAdmission()
        } else {
            _ = terminal.surface.admitStartupRestoreRuntime(
                initialInput: noticeInput
            )
        }
    }

    /// The live-agent scan did not finish inside the admission deadline, so
    /// liveness is unknown. Say so in each pane instead of leaving a bare
    /// prompt; the manual resume path re-checks ownership at exec (#12158).
    private func explainUnverifiableDeferredAgentResumeRestores() {
        for (panelId, restore) in Array(deferredAgentResumeRestoresByPanelId) {
            guard deferredAgentResumeRestoresByPanelId[panelId] != nil else {
                continue
            }
            guard let terminal = panels[panelId] as? TerminalPanel else {
                removeDeferredAgentResumeRestore(panelId: panelId)
                continue
            }
#if DEBUG
            cmuxDebugLog(
                "session.restore.admissionUnverifiable workspace=\(id.uuidString) panel=\(panelId.uuidString) kind=\(restore.restorableAgent?.kind.rawValue ?? restore.resumeBinding?.kind ?? "unknown")"
            )
#endif
            explainDeferredAgentResumeRestore(
                panelId: panelId,
                restore: restore,
                terminal: terminal,
                noticeInput: AgentRestoreUnverifiableNotice()
                    .startupInput(dialect: restore.noticeDialect)
            )
        }
        deferredAgentResumeRestoresByPanelId.removeAll()
    }

    func clearDeferredAgentResumeRestores(
        startRuntime: Bool = true,
        retireBindings: Bool = true
    ) {
        deferredAgentResumeIndexTask?.cancel()
        deferredAgentResumeIndexTask = nil
        let panelIds = Set(
            Array(deferredAgentResumeRestoresByPanelId.keys)
                + Array(deferredAgentResumeClaimsByPanelId.keys)
        )
        for panelId in panelIds {
            if let restore = deferredAgentResumeRestoresByPanelId[panelId] {
                cancelDeferredAgentResumeRestore(
                    panelId: panelId,
                    restore: restore,
                    startRuntime: startRuntime,
                    retireBinding: retireBindings
                )
            } else {
                if startRuntime {
                    (panels[panelId] as? TerminalPanel)?.surface.cancelStartupRestoreAdmission()
                } else {
                    terminalStartupRestoreCoordinator.discardPendingRestoreForPanelTeardown(panelID: panelId)
                    restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
                }
                removeDeferredAgentResumeRestore(panelId: panelId)
            }
        }
        deferredAgentResumeRestoresByPanelId.removeAll()
    }

    /// Uses the most recent completed index when a refresh could not settle.
    /// A missing refreshed index means the scan was inconclusive, not that the
    /// previously loaded session index is stale.
    nonisolated static func deferredResumeIndex(
        refreshed: RestorableAgentSessionIndex?,
        lastKnown: RestorableAgentSessionIndex?
    ) -> RestorableAgentSessionIndex? {
        refreshed ?? lastKnown
    }

    func agentHibernationLifecycleState(
        panelId: UUID,
        fallback: AgentHibernationLifecycleState?
    ) -> AgentHibernationLifecycleState {
        AgentHibernationLifecycleState.aggregate(
            statusKeyedStates: agentLifecycleStatesByPanelId[panelId] ?? [:],
            fallback: fallback
        )
    }

    func agentLifecycleStateForTextBoxEscape(panelId: UUID) -> AgentHibernationLifecycleState {
        AgentHibernationLifecycleState.aggregateForTextBoxEscape(
            statusKeyedStates: agentLifecycleStatesByPanelId[panelId] ?? [:]
        )
    }

    private func recordAgentLifecycleChange(panelId: UUID) {
        AgentHibernationController.shared.recordAgentLifecycleChange(
            workspaceId: id,
            panelId: panelId
        )
    }
}
