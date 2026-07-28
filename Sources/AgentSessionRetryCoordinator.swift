import CmuxSidebar
import CmuxWorkspaces
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AgentSessionRetryCoordinator {
    private enum Phase: Equatable {
        case waiting(attempt: Int, maximumAttempts: Int, exitCode: Int)
        case launching(attempt: Int, maximumAttempts: Int)
        case exhausted(maximumAttempts: Int)
    }

    private struct RetryState {
        var completedAttempts: Int
        var binding: SurfaceResumeBindingSnapshot
        var phase: Phase
        var timer: Timer?
    }

    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private let policy: AgentSessionRetryPolicy
    @ObservationIgnored private let settings: AgentSessionAutoRetrySettings
    @ObservationIgnored private var activePanelIds: Set<UUID> = []
    @ObservationIgnored private var awaitingCommandCompletionPanelIds: Set<UUID> = []
    @ObservationIgnored private var retryCandidatesByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
    @ObservationIgnored private var statesByPanelId: [UUID: RetryState] = [:]

    init(
        workspace: Workspace,
        policy: AgentSessionRetryPolicy = .standard,
        settings: AgentSessionAutoRetrySettings
    ) {
        self.workspace = workspace
        self.policy = policy
        self.settings = settings
    }

    deinit {
        for state in statesByPanelId.values {
            state.timer?.invalidate()
        }
    }

    func agentLifecycleDidChange(
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState
    ) {
        switch lifecycle {
        case .running, .needsInput:
            if case .waiting = statesByPanelId[panelId]?.phase {
                // A fresh hook arrived before our timer fired. A manual resume
                // or another live agent now owns the pane, so never inject a
                // second resume command.
                reset(panelId: panelId)
            } else if case .exhausted = statesByPanelId[panelId]?.phase {
                // A hook after exhaustion can only come from an explicit user
                // resume or a newly launched agent. Give that live run a fresh
                // retry budget.
                reset(panelId: panelId)
            } else if case .launching = statesByPanelId[panelId]?.phase {
                // The resumed agent has published a live hook. Keep the retry
                // count for a possible later failure, but the pane is no longer
                // waiting for recovery.
                workspace?.removeAgentRetryStatusEntry(panelId: panelId)
            }
            activePanelIds.insert(panelId)
            if let binding = workspace?.managedAgentRetryBinding(panelId: panelId) {
                retryCandidatesByPanelId[panelId] = binding
            }
        case .idle:
            if statesByPanelId[panelId] == nil,
               !awaitingCommandCompletionPanelIds.contains(panelId) {
                reset(panelId: panelId)
            }
        case .unknown:
            break
        }
    }

    func managedResumeBindingDidChange(
        panelId: UUID,
        binding: SurfaceResumeBindingSnapshot?
    ) {
        awaitingCommandCompletionPanelIds.remove(panelId)
        guard let binding,
              binding.isAgentHookBinding,
              binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            reset(panelId: panelId)
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
                reset(panelId: panelId)
            }
        }
        retryCandidatesByPanelId[panelId] = binding
    }

    func managedResumeBindingDidClear(
        panelId: UUID,
        binding: SurfaceResumeBindingSnapshot,
        sessionDidEnd: Bool
    ) {
        guard sessionDidEnd,
              binding.isAgentHookBinding,
              retryCandidatesByPanelId[panelId] == binding else {
            reset(panelId: panelId)
            return
        }
        // Managed session teardown deliberately removes the persistent binding
        // before Ghostty reports the command exit code. Keep this in-memory
        // candidate until that authoritative termination signal classifies it.
        awaitingCommandCompletionPanelIds.insert(panelId)
    }

    func agentLifecycleDidClear(panelId: UUID) {
        guard workspace?.hasActiveAgentLifecycleForRetry(panelId: panelId) != true,
              statesByPanelId[panelId] == nil,
              !awaitingCommandCompletionPanelIds.contains(panelId) else {
            return
        }
        reset(panelId: panelId)
    }

    func shellActivityDidChange(panelId: UUID, state: PanelShellActivityState) {
        guard state == .commandRunning else { return }
        if awaitingCommandCompletionPanelIds.contains(panelId) {
            // The ended managed command must produce the next command-finished
            // event before another shell command starts. If that event was lost or
            // delayed, a new command makes the pending exit ambiguous; fail closed
            // instead of letting its eventual exit resurrect the old agent.
            reset(panelId: panelId)
        } else if case .waiting = statesByPanelId[panelId]?.phase {
            reset(panelId: panelId)
        } else if case .exhausted = statesByPanelId[panelId]?.phase {
            reset(panelId: panelId)
        }
    }

    func commandFinished(panelId: UUID, exitCode: Int?) {
        guard let workspace else { return }
        if case .waiting = statesByPanelId[panelId]?.phase { return }
        if case .exhausted = statesByPanelId[panelId]?.phase { return }
        awaitingCommandCompletionPanelIds.remove(panelId)

        let binding = workspace.managedAgentRetryBinding(panelId: panelId) ??
            retryCandidatesByPanelId[panelId]
        let hadActiveSession = activePanelIds.contains(panelId) ||
            workspace.hasActiveAgentLifecycleForRetry(panelId: panelId)
        let completedAttempts = statesByPanelId[panelId]?.completedAttempts ?? 0
        let context = AgentSessionRetryContext(
            isEnabled: settings.isEnabled,
            hadActiveAgentSession: hadActiveSession,
            hasManagedResumeBinding: binding != nil,
            exitCode: exitCode
        )

        switch policy.decision(for: context, completedAttempts: completedAttempts) {
        case let .retry(attempt, maximumAttempts, delaySeconds):
            guard let binding, let exitCode else {
                reset(panelId: panelId)
                return
            }
            scheduleRetry(
                panelId: panelId,
                binding: binding,
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
                binding: binding
            )
        case .reject:
            reset(panelId: panelId)
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
        activePanelIds.removeAll()
        awaitingCommandCompletionPanelIds.removeAll()
        retryCandidatesByPanelId.removeAll()
        workspace?.removeAllAgentRetryStatusEntries()
    }

    private func scheduleRetry(
        panelId: UUID,
        binding: SurfaceResumeBindingSnapshot,
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

    private func retryTimerFired(panelId: UUID) {
        guard let workspace,
              let state = statesByPanelId[panelId],
              case let .waiting(attempt, maximumAttempts, _) = state.phase,
              settings.isEnabled,
              retryCandidatesByPanelId[panelId] == state.binding else {
            reset(panelId: panelId)
            return
        }

        let accepted = workspace.sendManagedAgentRetry(
            binding: state.binding,
            panelId: panelId
        )
        guard accepted else {
            workspace.showAgentRetryLaunchFailure(panelId: panelId)
            statesByPanelId[panelId] = RetryState(
                completedAttempts: attempt,
                binding: state.binding,
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
            phase: .launching(attempt: attempt, maximumAttempts: maximumAttempts),
            timer: nil
        )
        activePanelIds.insert(panelId)
        Self.logger.info(
            "Agent retry resume command sent panel=\(panelId, privacy: .public) attempt=\(attempt)/\(maximumAttempts)"
        )
    }

    private func markExhausted(
        panelId: UUID,
        exitCode: Int?,
        maximumAttempts: Int,
        binding: SurfaceResumeBindingSnapshot?
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
        statesByPanelId.removeValue(forKey: panelId)?.timer?.invalidate()
        activePanelIds.remove(panelId)
        awaitingCommandCompletionPanelIds.remove(panelId)
        retryCandidatesByPanelId.removeValue(forKey: panelId)
        workspace?.removeAgentRetryStatusEntry(panelId: panelId)
    }

    private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "AgentSessionAutoRetry"
    )
}
