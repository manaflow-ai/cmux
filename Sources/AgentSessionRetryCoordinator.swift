import CmuxSidebar
import CmuxWorkspaces
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AgentSessionRetryCoordinator {
    typealias RetryState = AgentSessionRetryPanelState
    private typealias Phase = AgentSessionRetryPanelState.Phase

    struct ManagedRunOwnership {
        let binding: SurfaceResumeBindingSnapshot
        let commandGeneration: UInt64
    }

    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored let policy: AgentSessionRetryPolicy
    @ObservationIgnored let settings: AgentSessionAutoRetrySettings
    @ObservationIgnored private var settingsDidChangeObserver: NSObjectProtocol?
    @ObservationIgnored var commandGenerationsByPanelId: [UUID: UInt64] = [:]
    @ObservationIgnored var managedRunsByPanelId: [UUID: ManagedRunOwnership] = [:]
    @ObservationIgnored private var endedSessionCandidatesByPanelId: [UUID: ManagedRunOwnership] = [:]
    @ObservationIgnored private var pendingManagedStartsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
    @ObservationIgnored var statesByPanelId: [UUID: RetryState] = [:]
    @ObservationIgnored var retryInputInjectionPanelIds: Set<UUID> = []

    init(
        workspace: Workspace,
        policy: AgentSessionRetryPolicy = .standard,
        settings: AgentSessionAutoRetrySettings
    ) {
        self.workspace = workspace
        self.policy = policy
        self.settings = settings
        self.settingsDidChangeObserver = nil
        self.settingsDidChangeObserver = settings.observeDidChange { [weak self] in
            guard let self, !self.settings.isEnabled else { return }
            self.cancelAll()
        }
    }

    deinit {
        for state in statesByPanelId.values {
            state.timer?.invalidate()
        }
        if let settingsDidChangeObserver {
            settings.removeDidChangeObserver(settingsDidChangeObserver)
        }
    }

    func agentLifecycleDidChange(
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState
    ) {
        switch lifecycle {
        case .running, .needsInput:
            // Lifecycle keys do not carry a session id. Bind them to a managed
            // run only while its exact resume checkpoint owns the current shell
            // command. A replay for an ended generation must not erase the
            // command-finished candidate.
            bindCurrentManagedRunIfPossible(panelId: panelId)
            recordHookFirstManagedStartIfPossible(panelId: panelId)
            if case .launching = statesByPanelId[panelId]?.phase {
                // The resumed agent has published a live hook. Keep the retry
                // count for a possible later failure, but the pane is no longer
                // waiting for recovery.
                workspace?.removeAgentRetryStatusEntry(panelId: panelId)
            }
        case .idle:
            if workspace?.hasActiveAgentLifecycleForRetry(panelId: panelId) != true {
                pendingManagedStartsByPanelId.removeValue(forKey: panelId)
            }
            attemptReadyRetry(panelId: panelId)
            if statesByPanelId[panelId] == nil,
               managedRunsByPanelId[panelId] == nil,
               endedSessionCandidatesByPanelId[panelId] == nil,
               commandGenerationsByPanelId[panelId] == nil {
                clearRecovery(panelId: panelId)
            }
        case .unknown:
            break
        }
    }

    func managedResumeBindingDidChange(
        panelId: UUID,
        binding: SurfaceResumeBindingSnapshot?
    ) {
        guard let binding,
              binding.isAgentHookBinding,
              binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            clearRecovery(panelId: panelId)
            return
        }

        // Any binding publication after a command was classified or ended is
        // live-session evidence that makes injection ambiguous. The next real
        // shell command will establish a fresh generation.
        if endedSessionCandidatesByPanelId[panelId] != nil ||
            statesByPanelId[panelId]?.phase.isWaitingOrExhausted == true {
            clearRecovery(panelId: panelId)
            return
        }

        if let state = statesByPanelId[panelId] {
            switch state.phase {
            case .launching where state.binding.checkpointId == binding.checkpointId &&
                    state.binding.kind == binding.kind:
                var updatedState = state
                updatedState.binding = binding
                statesByPanelId[panelId] = updatedState
            case .waiting, .ready, .launching, .exhausted:
                // A different managed session, or a manual resume while waiting
                // or exhausted, owns the pane now and starts with a fresh budget.
                clearRecovery(panelId: panelId)
                return
            }
        }
        bindCurrentManagedRunIfPossible(panelId: panelId)
        recordHookFirstManagedStartIfPossible(panelId: panelId)
    }

    func managedResumeBindingDidClear(
        panelId: UUID,
        binding: SurfaceResumeBindingSnapshot,
        sessionDidEnd: Bool
    ) {
        if let state = statesByPanelId[panelId],
           state.phase.isWaitingOrExhausted,
           state.binding.isSameManagedSession(as: binding),
           state.commandGeneration == commandGenerationsByPanelId[panelId],
           sessionDidEnd {
            // command-finished may be delivered before the hook's socket clear.
            // The already-classified generation remains authoritative.
            attemptReadyRetry(panelId: panelId)
            return
        }

        guard settings.isEnabled,
              sessionDidEnd,
              binding.isAgentHookBinding,
              binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let ownedRun = managedRunsByPanelId[panelId],
              ownedRun.binding.isSameManagedSession(as: binding),
              ownedRun.commandGeneration == commandGenerationsByPanelId[panelId] else {
            clearRecovery(panelId: panelId)
            return
        }
        endedSessionCandidatesByPanelId[panelId] = ManagedRunOwnership(
            binding: binding,
            commandGeneration: ownedRun.commandGeneration
        )
        managedRunsByPanelId.removeValue(forKey: panelId)
    }

    func agentLifecycleDidClear(panelId: UUID) {
        if workspace?.hasActiveAgentLifecycleForRetry(panelId: panelId) != true {
            pendingManagedStartsByPanelId.removeValue(forKey: panelId)
        }
        attemptReadyRetry(panelId: panelId)
        guard workspace?.hasActiveAgentLifecycleForRetry(panelId: panelId) != true,
              statesByPanelId[panelId] == nil,
              managedRunsByPanelId[panelId] == nil,
              endedSessionCandidatesByPanelId[panelId] == nil else {
            return
        }
        clearRecovery(panelId: panelId)
    }

    func shellActivityDidChange(panelId: UUID, state: PanelShellActivityState) {
        guard state == .commandRunning else {
            if state == .promptIdle {
                attemptReadyRetry(panelId: panelId)
            }
            return
        }
        let pendingManagedStart = pendingManagedStartsByPanelId.removeValue(forKey: panelId)
        let nextGeneration = (commandGenerationsByPanelId[panelId] ?? 0) &+ 1

        if var state = statesByPanelId[panelId], case .launching = state.phase {
            // This is the retry command accepted by sendManagedAgentRetry. Carry
            // its bounded-attempt state into the new shell generation.
            state.commandGeneration = nextGeneration
            statesByPanelId[panelId] = state
            managedRunsByPanelId.removeValue(forKey: panelId)
            endedSessionCandidatesByPanelId.removeValue(forKey: panelId)
        } else {
            // A user-started command supersedes every unconsumed completion and
            // every scheduled/exhausted retry for the prior generation.
            clearRecovery(panelId: panelId)
        }
        commandGenerationsByPanelId[panelId] = nextGeneration

        // Hooks can win the cross-process race with the shell-state report for
        // a retry cmux launched itself. In that one case, existing live signals
        // are safe to bind to the generation that just began.
        if case .launching = statesByPanelId[panelId]?.phase {
            bindCurrentManagedRunIfPossible(panelId: panelId, shellIsRunning: true)
        } else if let pendingManagedStart,
                  let workspace,
                  workspace.hasActiveAgentLifecycleForRetry(panelId: panelId),
                  workspace.managedAgentRetryBinding(panelId: panelId)?.isSameManagedSession(
                      as: pendingManagedStart
                  ) == true {
            managedRunsByPanelId[panelId] = ManagedRunOwnership(
                binding: pendingManagedStart,
                commandGeneration: nextGeneration
            )
        }
    }

    func commandFinished(panelId: UUID, exitCode: Int?) {
        guard workspace != nil else { return }
        if statesByPanelId[panelId]?.phase.isWaitingOrExhausted == true { return }
        guard let commandGeneration = commandGenerationsByPanelId[panelId],
              let candidate = commandFinishedCandidate(
                  panelId: panelId,
                  commandGeneration: commandGeneration
              ) else {
            clearRecovery(panelId: panelId)
            return
        }
        let completedAttempts = statesByPanelId[panelId]?.completedAttempts ?? 0
        let context = AgentSessionRetryContext(
            isEnabled: settings.isEnabled,
            hadActiveAgentSession: true,
            hasManagedResumeBinding: true,
            exitCode: exitCode
        )

        switch policy.decision(for: context, completedAttempts: completedAttempts) {
        case let .retry(attempt, maximumAttempts, delaySeconds):
            guard let exitCode else {
                reset(panelId: panelId)
                return
            }
            scheduleRetry(
                panelId: panelId,
                binding: candidate.binding,
                commandGeneration: commandGeneration,
                exitCode: exitCode,
                attempt: attempt,
                maximumAttempts: maximumAttempts,
                delaySeconds: delaySeconds
            )
        case let .exhausted(maximumAttempts):
            markExhausted(
                panelId: panelId,
                exitCode: exitCode,
                maximumAttempts: maximumAttempts,
                binding: candidate.binding,
                commandGeneration: commandGeneration
            )
        case .reject:
            clearRecovery(panelId: panelId)
        }
    }

    /// Cancels a delayed retry before user input can share its shell prompt.
    func explicitTerminalInputDidBegin(panelId: UUID) {
        guard !retryInputInjectionPanelIds.contains(panelId) else { return }
        let promptIsIdle = workspace?.panelShellActivityStates[panelId] == .promptIdle
        let hasUnclassifiedRun = managedRunsByPanelId[panelId] != nil ||
            endedSessionCandidatesByPanelId[panelId] != nil ||
            pendingManagedStartsByPanelId[panelId] != nil
        guard statesByPanelId[panelId]?.phase.isWaitingOrExhausted == true ||
                (promptIsIdle && hasUnclassifiedRun) else { return }
        reset(panelId: panelId)
    }

    func cancel(panelId: UUID) {
        reset(panelId: panelId)
    }

    func cancelAll() {
        for state in statesByPanelId.values {
            state.timer?.invalidate()
        }
        statesByPanelId.removeAll()
        commandGenerationsByPanelId.removeAll()
        managedRunsByPanelId.removeAll()
        endedSessionCandidatesByPanelId.removeAll()
        pendingManagedStartsByPanelId.removeAll()
        workspace?.removeAllAgentRetryStatusEntries()
    }

    private func markExhausted(
        panelId: UUID,
        exitCode: Int?,
        maximumAttempts: Int,
        binding: SurfaceResumeBindingSnapshot?,
        commandGeneration: UInt64
    ) {
        let retainedBinding = binding ?? statesByPanelId[panelId]?.binding
        guard let retainedBinding else {
            reset(panelId: panelId)
            return
        }
        statesByPanelId[panelId]?.timer?.invalidate()
        statesByPanelId[panelId] = RetryState(
            completedAttempts: maximumAttempts,
            binding: retainedBinding,
            commandGeneration: commandGeneration,
            phase: .exhausted(maximumAttempts: maximumAttempts),
            timer: nil
        )
        workspace?.showAgentRetriesExhausted(
            panelId: panelId,
            exitCode: exitCode,
            maximumAttempts: maximumAttempts
        )
        Self.logger.error(
            "Agent automatic retries exhausted panel=\(panelId, privacy: .public) exit=\(exitCode ?? -1) attempts=\(maximumAttempts)"
        )
    }

    func reset(panelId: UUID) {
        clearRecovery(panelId: panelId)
        commandGenerationsByPanelId.removeValue(forKey: panelId)
    }

    private func clearRecovery(panelId: UUID) {
        statesByPanelId.removeValue(forKey: panelId)?.timer?.invalidate()
        managedRunsByPanelId.removeValue(forKey: panelId)
        endedSessionCandidatesByPanelId.removeValue(forKey: panelId)
        pendingManagedStartsByPanelId.removeValue(forKey: panelId)
        workspace?.removeAgentRetryStatusEntry(panelId: panelId)
    }

    private func recordHookFirstManagedStartIfPossible(panelId: UUID) {
        guard let workspace,
              workspace.panelShellActivityStates[panelId] != .commandRunning,
              statesByPanelId[panelId] == nil,
              managedRunsByPanelId[panelId] == nil,
              endedSessionCandidatesByPanelId[panelId] == nil,
              workspace.hasActiveAgentLifecycleForRetry(panelId: panelId),
              let binding = workspace.managedAgentRetryBinding(panelId: panelId) else {
            return
        }
        pendingManagedStartsByPanelId[panelId] = binding
    }

    private func bindCurrentManagedRunIfPossible(
        panelId: UUID,
        shellIsRunning: Bool? = nil
    ) {
        guard let workspace,
              shellIsRunning ?? (workspace.panelShellActivityStates[panelId] == .commandRunning),
              workspace.hasActiveAgentLifecycleForRetry(panelId: panelId),
              let binding = workspace.managedAgentRetryBinding(panelId: panelId),
              let commandGeneration = commandGenerationsByPanelId[panelId] else {
            return
        }
        managedRunsByPanelId[panelId] = ManagedRunOwnership(
            binding: binding,
            commandGeneration: commandGeneration
        )
    }

    private func commandFinishedCandidate(
        panelId: UUID,
        commandGeneration: UInt64
    ) -> ManagedRunOwnership? {
        if let ended = endedSessionCandidatesByPanelId.removeValue(forKey: panelId),
           ended.commandGeneration == commandGeneration {
            return ended
        }
        guard let workspace,
              let ownedRun = managedRunsByPanelId.removeValue(forKey: panelId),
              ownedRun.commandGeneration == commandGeneration,
              workspace.managedAgentRetryBinding(panelId: panelId)?.isSameManagedSession(
                  as: ownedRun.binding
              ) == true else {
            return nil
        }
        return ownedRun
    }

    static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "AgentSessionAutoRetry"
    )
    static let readinessTimeoutSeconds: TimeInterval = 30
}

extension SurfaceResumeBindingSnapshot {
    func isSameManagedSession(as other: SurfaceResumeBindingSnapshot) -> Bool {
        source == "agent-hook" &&
            other.source == "agent-hook" &&
            kind == other.kind &&
            checkpointId == other.checkpointId
    }
}
