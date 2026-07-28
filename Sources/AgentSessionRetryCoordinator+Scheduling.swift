import Foundation
import OSLog

extension AgentSessionRetryCoordinator {
    func scheduleRetry(
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
        guard workspace != nil,
              let state = statesByPanelId[panelId] else {
            reset(panelId: panelId)
            return
        }
        guard case let .waiting(attempt, maximumAttempts, _) = state.phase else {
            return
        }
        guard settings.isEnabled,
              commandGenerationsByPanelId[panelId] == state.commandGeneration else {
            reset(panelId: panelId)
            return
        }

        state.timer?.invalidate()
        let readinessTimer = Timer(
            timeInterval: Self.readinessTimeoutSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.retryReadinessDeadlineFired(panelId: panelId)
            }
        }
        statesByPanelId[panelId] = RetryState(
            completedAttempts: state.completedAttempts,
            binding: state.binding,
            commandGeneration: state.commandGeneration,
            phase: .ready(attempt: attempt, maximumAttempts: maximumAttempts),
            timer: readinessTimer
        )
        RunLoop.main.add(readinessTimer, forMode: .common)
        attemptReadyRetry(panelId: panelId)
    }

    func retryReadinessDeadlineFired(panelId: UUID) {
        guard case .ready = statesByPanelId[panelId]?.phase else { return }
        Self.logger.warning(
            "Agent retry cancelled while waiting for authoritative shell idle panel=\(panelId, privacy: .public)"
        )
        reset(panelId: panelId)
    }

    func attemptReadyRetry(panelId: UUID) {
        guard let workspace,
              let state = statesByPanelId[panelId],
              case let .ready(attempt, maximumAttempts) = state.phase else {
            return
        }
        guard settings.isEnabled,
              commandGenerationsByPanelId[panelId] == state.commandGeneration else {
            reset(panelId: panelId)
            return
        }
        switch workspace.managedAgentRetryLaunchReadiness(
            binding: state.binding,
            panelId: panelId
        ) {
        case .awaitingIdle:
            return
        case .invalidated:
            reset(panelId: panelId)
            return
        case .ready:
            break
        }

        state.timer?.invalidate()
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

        let launchTimer = Timer(
            timeInterval: Self.launchAcknowledgementTimeoutSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.retryLaunchAcknowledgementDeadlineFired(panelId: panelId)
            }
        }
        statesByPanelId[panelId] = RetryState(
            completedAttempts: attempt,
            binding: state.binding,
            commandGeneration: state.commandGeneration,
            phase: .awaitingLaunch(attempt: attempt, maximumAttempts: maximumAttempts),
            timer: launchTimer
        )
        RunLoop.main.add(launchTimer, forMode: .common)
        Self.logger.info(
            "Agent retry resume command sent panel=\(panelId, privacy: .public) attempt=\(attempt)/\(maximumAttempts)"
        )
    }

    func retryLaunchAcknowledgementDeadlineFired(panelId: UUID) {
        guard case .awaitingLaunch = statesByPanelId[panelId]?.phase else { return }
        Self.logger.warning(
            "Agent retry cancelled while waiting for launch acknowledgement panel=\(panelId, privacy: .public)"
        )
        reset(panelId: panelId)
    }
}
