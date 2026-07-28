import CmuxSidebar
import CmuxWorkspaces
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AgentSessionRetryCoordinator {
    private typealias RetryState = AgentSessionRetryPanelState
    private typealias Phase = AgentSessionRetryPanelState.Phase

    private struct ManagedRunOwnership {
        let binding: SurfaceResumeBindingSnapshot
        let commandGeneration: UInt64
    }

    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private let policy: AgentSessionRetryPolicy
    @ObservationIgnored private let settings: AgentSessionAutoRetrySettings
    @ObservationIgnored private var settingsDidChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var commandGenerationsByPanelId: [UUID: UInt64] = [:]
    @ObservationIgnored private var managedRunsByPanelId: [UUID: ManagedRunOwnership] = [:]
    @ObservationIgnored private var endedSessionCandidatesByPanelId: [UUID: ManagedRunOwnership] = [:]
    @ObservationIgnored private var statesByPanelId: [UUID: RetryState] = [:]
    @ObservationIgnored private var retryInputInjectionPanelIds: Set<UUID> = []

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
            if case .launching = statesByPanelId[panelId]?.phase {
                // The resumed agent has published a live hook. Keep the retry
                // count for a possible later failure, but the pane is no longer
                // waiting for recovery.
                workspace?.removeAgentRetryStatusEntry(panelId: panelId)
            }
        case .idle:
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
            case .waiting, .launching, .exhausted:
                // A different managed session, or a manual resume while waiting
                // or exhausted, owns the pane now and starts with a fresh budget.
                clearRecovery(panelId: panelId)
                return
            }
        }
        bindCurrentManagedRunIfPossible(panelId: panelId)
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
        guard workspace?.hasActiveAgentLifecycleForRetry(panelId: panelId) != true,
              statesByPanelId[panelId] == nil,
              managedRunsByPanelId[panelId] == nil,
              endedSessionCandidatesByPanelId[panelId] == nil else {
            return
        }
        clearRecovery(panelId: panelId)
    }

    func shellActivityDidChange(panelId: UUID, state: PanelShellActivityState) {
        guard state == .commandRunning else { return }
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
        }
    }

    func commandFinished(panelId: UUID, exitCode: Int?) {
        guard workspace != nil else { return }
        if case .waiting = statesByPanelId[panelId]?.phase { return }
        if case .exhausted = statesByPanelId[panelId]?.phase { return }
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
        let hasUnclassifiedRun = managedRunsByPanelId[panelId] != nil || endedSessionCandidatesByPanelId[panelId] != nil
        guard statesByPanelId[panelId]?.phase.isWaitingOrExhausted == true ||
                (promptIsIdle && hasUnclassifiedRun) else { return }
        reset(panelId: panelId)
    }
    /// Captures proof that a transferred pane's managed checkpoint owns its command.
    func transferredCompletedAttempts(
        panelId: UUID,
        shellActivityState: PanelShellActivityState?,
        binding: SurfaceResumeBindingSnapshot?
    ) -> Int? {
        guard settings.isEnabled,
              shellActivityState == .commandRunning,
              let binding,
              let commandGeneration = commandGenerationsByPanelId[panelId],
              let ownedRun = managedRunsByPanelId[panelId],
              ownedRun.commandGeneration == commandGeneration,
              ownedRun.binding.isSameManagedSession(as: binding) else {
            return nil
        }
        return statesByPanelId[panelId]?.completedAttempts ?? 0
    }

    /// Reconstructs transferred command ownership; missing or stale facts fail closed.
    func seedTransferredManagedRun(
        panelId: UUID,
        shellActivityState: PanelShellActivityState?,
        binding: SurfaceResumeBindingSnapshot?,
        completedAttempts: Int?
    ) {
        guard settings.isEnabled,
              shellActivityState == .commandRunning,
              let binding,
              binding.isAgentHookBinding,
              binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let completedAttempts,
              completedAttempts >= 0,
              completedAttempts <= policy.maximumAttempts else {
            reset(panelId: panelId)
            return
        }

        let commandGeneration = (commandGenerationsByPanelId[panelId] ?? 0) &+ 1
        commandGenerationsByPanelId[panelId] = commandGeneration
        managedRunsByPanelId[panelId] = ManagedRunOwnership(
            binding: binding,
            commandGeneration: commandGeneration
        )
        if completedAttempts > 0 {
            statesByPanelId[panelId] = RetryState(
                completedAttempts: completedAttempts,
                binding: binding,
                commandGeneration: commandGeneration,
                phase: .launching(
                    attempt: completedAttempts,
                    maximumAttempts: policy.maximumAttempts
                ),
                timer: nil
            )
        }
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
        workspace?.removeAllAgentRetryStatusEntries()
    }

    private func scheduleRetry(
        panelId: UUID,
        binding: SurfaceResumeBindingSnapshot,
        commandGeneration: UInt64,
        exitCode: Int,
        attempt: Int,
        maximumAttempts: Int,
        delaySeconds: TimeInterval
    ) {
        statesByPanelId[panelId]?.timer?.invalidate()
        let timer = Timer(timeInterval: delaySeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.retryTimerFired(panelId: panelId)
            }
        }
        statesByPanelId[panelId] = RetryState(
            completedAttempts: attempt - 1,
            binding: binding,
            commandGeneration: commandGeneration,
            phase: .waiting(
                attempt: attempt,
                maximumAttempts: maximumAttempts,
                exitCode: exitCode
            ),
            timer: timer
        )
        RunLoop.main.add(timer, forMode: .common)

        workspace?.showAgentRetryScheduled(
            panelId: panelId,
            exitCode: exitCode,
            attempt: attempt,
            maximumAttempts: maximumAttempts
        )
        Self.logger.warning(
            "Agent session exited abnormally; scheduling retry panel=\(panelId, privacy: .public) exit=\(exitCode) attempt=\(attempt)/\(maximumAttempts) delaySeconds=\(delaySeconds)"
        )
    }

    func retryTimerFired(panelId: UUID) {
        guard let workspace,
              let state = statesByPanelId[panelId],
              case let .waiting(attempt, maximumAttempts, _) = state.phase,
              settings.isEnabled,
              commandGenerationsByPanelId[panelId] == state.commandGeneration,
              workspace.canSafelySendManagedAgentRetry(
                  binding: state.binding,
                  panelId: panelId
              ) else {
            reset(panelId: panelId)
            return
        }

        let accepted = workspace.sendManagedAgentRetry(
            binding: state.binding,
            panelId: panelId,
            beforeSending: { [weak self] in
                self?.retryInputInjectionPanelIds.insert(panelId)
            },
            afterSending: { [weak self] in
                self?.retryInputInjectionPanelIds.remove(panelId)
            }
        )
        guard accepted else {
            workspace.showAgentRetryLaunchFailure(panelId: panelId)
            statesByPanelId[panelId] = RetryState(
                completedAttempts: attempt,
                binding: state.binding,
                commandGeneration: state.commandGeneration,
                phase: .exhausted(maximumAttempts: maximumAttempts),
                timer: nil
            )
            Self.logger.error(
                "Agent retry resume command was not accepted panel=\(panelId, privacy: .public) attempt=\(attempt)/\(maximumAttempts)"
            )
            return
        }

        statesByPanelId[panelId] = RetryState(
            completedAttempts: attempt,
            binding: state.binding,
            commandGeneration: state.commandGeneration,
            phase: .launching(attempt: attempt, maximumAttempts: maximumAttempts),
            timer: nil
        )
        Self.logger.info(
            "Agent retry resume command sent panel=\(panelId, privacy: .public) attempt=\(attempt)/\(maximumAttempts)"
        )
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

    private func reset(panelId: UUID) {
        clearRecovery(panelId: panelId)
        commandGenerationsByPanelId.removeValue(forKey: panelId)
    }

    private func clearRecovery(panelId: UUID) {
        statesByPanelId.removeValue(forKey: panelId)?.timer?.invalidate()
        managedRunsByPanelId.removeValue(forKey: panelId)
        endedSessionCandidatesByPanelId.removeValue(forKey: panelId)
        workspace?.removeAgentRetryStatusEntry(panelId: panelId)
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

    private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "AgentSessionAutoRetry"
    )
}

private extension SurfaceResumeBindingSnapshot {
    func isSameManagedSession(as other: SurfaceResumeBindingSnapshot) -> Bool {
        source == "agent-hook" &&
            other.source == "agent-hook" &&
            kind == other.kind &&
            checkpointId == other.checkpointId
    }
}
