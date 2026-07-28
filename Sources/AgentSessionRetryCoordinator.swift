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

    private struct EndedSessionCandidate {
        let binding: SurfaceResumeBindingSnapshot
        let hadActiveAgentSession: Bool
    }

    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private let policy: AgentSessionRetryPolicy
    @ObservationIgnored private let settings: AgentSessionAutoRetrySettings
    @ObservationIgnored private var settingsDidChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var activePanelIds: Set<UUID> = []
    @ObservationIgnored private var endedSessionCandidatesByPanelId: [UUID: EndedSessionCandidate] = [:]
    @ObservationIgnored private var statesByPanelId: [UUID: RetryState] = [:]

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
            endedSessionCandidatesByPanelId.removeValue(forKey: panelId)
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
        case .idle:
            if statesByPanelId[panelId] == nil,
               endedSessionCandidatesByPanelId[panelId] == nil {
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
        endedSessionCandidatesByPanelId.removeValue(forKey: panelId)
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
    }

    func managedResumeBindingDidClear(
        panelId: UUID,
        binding: SurfaceResumeBindingSnapshot,
        sessionDidEnd: Bool
    ) {
        let hadActiveAgentSession = activePanelIds.contains(panelId) ||
            workspace?.hasActiveAgentLifecycleForRetry(panelId: panelId) == true
        guard settings.isEnabled,
              sessionDidEnd,
              binding.isAgentHookBinding,
              binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              hadActiveAgentSession else {
            reset(panelId: panelId)
            return
        }
        // This exact binding is the only authority command-finished may consume.
        // A panel-current binding can already belong to a replacement session.
        endedSessionCandidatesByPanelId[panelId] = EndedSessionCandidate(
            binding: binding,
            hadActiveAgentSession: hadActiveAgentSession
        )
        activePanelIds.remove(panelId)
    }

    func agentLifecycleDidClear(panelId: UUID) {
        guard workspace?.hasActiveAgentLifecycleForRetry(panelId: panelId) != true,
              statesByPanelId[panelId] == nil,
              endedSessionCandidatesByPanelId[panelId] == nil else {
            return
        }
        reset(panelId: panelId)
    }

    func shellActivityDidChange(panelId: UUID, state: PanelShellActivityState) {
        guard state == .commandRunning else { return }
        if endedSessionCandidatesByPanelId[panelId] != nil {
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
        guard workspace != nil else { return }
        if case .waiting = statesByPanelId[panelId]?.phase { return }
        if case .exhausted = statesByPanelId[panelId]?.phase { return }
        guard let candidate = endedSessionCandidatesByPanelId.removeValue(forKey: panelId) else {
            reset(panelId: panelId)
            return
        }
        let completedAttempts = statesByPanelId[panelId]?.completedAttempts ?? 0
        let context = AgentSessionRetryContext(
            isEnabled: settings.isEnabled,
            hadActiveAgentSession: candidate.hadActiveAgentSession,
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
                binding: candidate.binding
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
        endedSessionCandidatesByPanelId.removeAll()
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

    func retryTimerFired(panelId: UUID) {
        guard let workspace,
              let state = statesByPanelId[panelId],
              case let .waiting(attempt, maximumAttempts, _) = state.phase,
              settings.isEnabled,
              workspace.canSafelySendManagedAgentRetry(
                  binding: state.binding,
                  panelId: panelId
              ) else {
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
        endedSessionCandidatesByPanelId.removeValue(forKey: panelId)
        workspace?.removeAgentRetryStatusEntry(panelId: panelId)
    }

    private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "AgentSessionAutoRetry"
    )
}
