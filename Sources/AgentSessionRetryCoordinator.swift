import CmuxSidebar
import CmuxWorkspaces
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AgentSessionRetryCoordinator {
    typealias RetryState = AgentSessionRetryPanelState

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
            acknowledgeInjectedRetryFromHooksIfPossible(panelId: panelId)
        case .idle:
            if workspace?.hasActiveAgentLifecycleForRetry(panelId: panelId) != true {
                pendingManagedStartsByPanelId.removeValue(forKey: panelId)
            }
            if case .running = statesByPanelId[panelId]?.phase,
               managedRunsByPanelId[panelId] == nil,
               endedSessionCandidatesByPanelId[panelId] == nil,
               workspace?.panelShellActivityStates[panelId] != .commandRunning {
                reset(panelId: panelId)
                return
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
            statesByPanelId[panelId]?.phase.isWaitingOrReadyOrExhausted == true {
            clearRecovery(panelId: panelId)
            return
        }

        if let state = statesByPanelId[panelId] {
            switch state.phase {
            case .awaitingLaunch, .running:
                if state.binding.isSameManagedSession(as: binding) {
                    var updatedState = state
                    updatedState.binding = binding
                    statesByPanelId[panelId] = updatedState
                } else {
                    clearRecovery(panelId: panelId)
                    return
                }
            case .waiting, .ready, .exhausted:
                // A different managed session, or a manual resume while waiting
                // or exhausted, owns the pane now and starts with a fresh budget.
                clearRecovery(panelId: panelId)
                return
            }
        }
        bindCurrentManagedRunIfPossible(panelId: panelId)
        recordHookFirstManagedStartIfPossible(panelId: panelId)
        acknowledgeInjectedRetryFromHooksIfPossible(
            panelId: panelId,
            bindingPublicationIsEvidence: true
        )
    }

    func managedResumeBindingDidClear(
        panelId: UUID,
        binding: SurfaceResumeBindingSnapshot,
        sessionDidEnd: Bool
    ) {
        if let state = statesByPanelId[panelId],
           state.phase.isWaitingOrReadyOrExhausted,
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
                preserveOwnedRunAtPromptIdle(panelId: panelId)
                attemptReadyRetry(panelId: panelId)
            }
            return
        }
        let pendingManagedStart = pendingManagedStartsByPanelId.removeValue(forKey: panelId)
        let nextGeneration = (commandGenerationsByPanelId[panelId] ?? 0) &+ 1

        var retainedInjectedRetryBinding: SurfaceResumeBindingSnapshot?
        if var retryState = statesByPanelId[panelId] {
            switch retryState.phase {
            case let .awaitingLaunch(attempt, maximumAttempts),
                 let .running(attempt, maximumAttempts):
                retryState.timer?.invalidate()
                retryState.commandGeneration = nextGeneration
                retryState.phase = .running(
                    attempt: attempt,
                    maximumAttempts: maximumAttempts
                )
                retryState.timer = nil
                statesByPanelId[panelId] = retryState
                retainedInjectedRetryBinding = retryState.binding
            case .waiting, .ready, .exhausted:
                clearRecovery(panelId: panelId)
            }
        } else {
            // A user-started command supersedes every unconsumed completion and
            // every scheduled/exhausted retry for the prior generation.
            clearRecovery(panelId: panelId)
        }
        if let retainedInjectedRetryBinding {
            managedRunsByPanelId.removeValue(forKey: panelId)
            endedSessionCandidatesByPanelId.removeValue(forKey: panelId)
            managedRunsByPanelId[panelId] = ManagedRunOwnership(
                binding: retainedInjectedRetryBinding,
                commandGeneration: nextGeneration
            )
            workspace?.removeAgentRetryStatusEntry(panelId: panelId)
        }
        commandGenerationsByPanelId[panelId] = nextGeneration

        if retainedInjectedRetryBinding == nil,
           let pendingManagedStart,
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
        if statesByPanelId[panelId]?.phase.isWaitingOrReadyOrExhausted == true { return }
        guard let commandGeneration = commandGenerationsByPanelId[panelId] else {
            clearRecovery(panelId: panelId)
            return
        }
        let candidate: ManagedRunOwnership
        if let state = statesByPanelId[panelId],
           case .awaitingLaunch = state.phase,
           state.commandGeneration == commandGeneration {
            // The accepted retry injection is itself authoritative ownership.
            // Explicit input and the acknowledgement deadline both cancel this
            // phase, so a command-finished event that wins the start-hook race
            // belongs to the injected resume attempt.
            candidate = ManagedRunOwnership(
                binding: state.binding,
                commandGeneration: commandGeneration
            )
        } else if let ownedCandidate = commandFinishedCandidate(
            panelId: panelId,
            commandGeneration: commandGeneration
        ) {
            candidate = ownedCandidate
        } else {
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
        guard statesByPanelId[panelId]?.phase.isPendingOrExhausted == true ||
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

    private func acknowledgeInjectedRetryFromHooksIfPossible(
        panelId: UUID,
        bindingPublicationIsEvidence: Bool = false
    ) {
        guard let workspace,
              var state = statesByPanelId[panelId],
              case let .awaitingLaunch(attempt, maximumAttempts) = state.phase,
              let binding = workspace.managedAgentRetryBinding(panelId: panelId),
              state.binding.isSameManagedSession(as: binding),
              bindingPublicationIsEvidence ||
                workspace.hasActiveAgentLifecycleForRetry(panelId: panelId) else {
            return
        }
        state.timer?.invalidate()
        state.binding = binding
        state.phase = .running(attempt: attempt, maximumAttempts: maximumAttempts)
        state.timer = nil
        statesByPanelId[panelId] = state
        pendingManagedStartsByPanelId[panelId] = binding
        workspace.removeAgentRetryStatusEntry(panelId: panelId)
    }

    private func preserveOwnedRunAtPromptIdle(panelId: UUID) {
        guard endedSessionCandidatesByPanelId[panelId] == nil,
              let workspace,
              let commandGeneration = commandGenerationsByPanelId[panelId],
              let ownedRun = managedRunsByPanelId[panelId],
              ownedRun.commandGeneration == commandGeneration else {
            return
        }
        if let currentBinding = workspace.managedAgentRetryBinding(panelId: panelId),
           !ownedRun.binding.isSameManagedSession(as: currentBinding) {
            clearRecovery(panelId: panelId)
            return
        }
        endedSessionCandidatesByPanelId[panelId] = ownedRun
        managedRunsByPanelId.removeValue(forKey: panelId)
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
    static let launchAcknowledgementTimeoutSeconds: TimeInterval = 30
}

extension SurfaceResumeBindingSnapshot {
    func isSameManagedSession(as other: SurfaceResumeBindingSnapshot) -> Bool {
        source == "agent-hook" &&
            other.source == "agent-hook" &&
            kind == other.kind &&
            checkpointId == other.checkpointId
    }
}
