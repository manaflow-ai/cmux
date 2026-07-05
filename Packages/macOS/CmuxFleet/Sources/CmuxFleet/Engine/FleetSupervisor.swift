import Foundation

/// Reduces one Fleet task snapshot with one deterministic supervision signal.
public struct FleetSupervisor: Sendable {
    /// Applies a signal to a task without performing I/O or reading the clock.
    /// - Parameters:
    ///   - task: The current task snapshot.
    ///   - signal: The deterministic signal to apply.
    ///   - config: The supervision limits used for retry decisions.
    /// - Returns: The next task snapshot and imperative commands for the engine.
    public static func reduce(
        task: FleetTask,
        signal: FleetSignal,
        config: FleetSupervisionConfig = FleetSupervisionConfig()
    ) -> (FleetTask, [FleetCommand]) {
        switch signal {
        case .sourceSync:
            return (task, [])
        case let .provisioned(taskID, path, _, at):
            guard taskID == task.id, task.state == .provisioning else {
                return (task, [])
            }
            var next = task
            next.directoryPath = path
            next.lastError = nil
            return startAttempt(
                task: next,
                command: { .launchAgent(task: $0, attempt: $1) },
                at: at
            )
        case let .provisionFailed(taskID, message, at):
            guard taskID == task.id, task.state == .provisioning else {
                return (task, [])
            }
            var next = task
            next.lastError = message
            return transition(task: next, to: .failed, at: at)
        case let .agentSessionStarted(taskID, sessionID, pid, at):
            guard taskID == task.id, task.state == .launching else {
                return (task, [])
            }
            _ = sessionID
            _ = pid
            return transition(task: task, to: .running, at: at)
        case let .activity(taskID, at):
            guard taskID == task.id, !task.state.isTerminal else {
                return (task, [])
            }
            var next = task
            next.lastActivityAt = at
            next.updatedAt = at
            return (next, [])
        case let .blockingItemReceived(taskID, at):
            guard taskID == task.id, task.state == .running else {
                return (task, [])
            }
            var next = task
            next.isBlocked = true
            let transitioned = transition(task: next, to: .needsInput, at: at)
            return (transitioned.0, transitioned.1 + [
                .postNotification(taskID: task.id, kind: .needsInput),
            ])
        case let .blockingItemResolved(taskID, at):
            guard taskID == task.id, task.state == .needsInput else {
                return (task, [])
            }
            var next = task
            next.isBlocked = false
            return transition(task: next, to: .running, at: at)
        case let .agentStopped(taskID, at):
            guard taskID == task.id, acceptsAgentStop(from: task.state) else {
                return (task, [])
            }
            if task.pr != nil {
                return transition(task: task, to: .awaitingReview, at: at)
            }
            return retryOrFail(task: task, config: config, at: at, killAgent: false)
        case let .pidExited(taskID, at), let .promptIdleObserved(taskID, at):
            guard taskID == task.id, task.state == .running else {
                return (task, [])
            }
            return retryOrFail(task: task, config: config, at: at, killAgent: false)
        case let .stallTimeout(taskID, at):
            guard taskID == task.id, task.state == .running || task.state == .needsInput else {
                return (task, [])
            }
            return retryOrFail(task: task, config: config, at: at, killAgent: true)
        case let .backoffElapsed(taskID, at):
            guard taskID == task.id, task.state == .retryBackoff else {
                return (task, [])
            }
            return startAttempt(
                task: task,
                command: { .resendAgentCommand(task: $0, attempt: $1) },
                at: at
            )
        case let .workspaceClosed(taskID, at):
            guard taskID == task.id, !task.state.isTerminal else {
                return (task, [])
            }
            return transition(task: task, to: .cancelled, at: at)
        case let .prChanged(taskID, pr, at):
            guard taskID == task.id else {
                return (task, [])
            }
            var next = task
            next.pr = pr
            if task.state == .awaitingReview, pr.isTerminal {
                let transitioned = transition(task: next, to: .done, at: at)
                return (transitioned.0, transitioned.1 + [.cleanupWorkspace(task: transitioned.0)])
            }
            next.updatedAt = at
            return (next, [])
        case let .sourceReachedTerminalState(taskID, at):
            guard taskID == task.id else {
                return (task, [])
            }
            if task.state == .queued {
                return transition(task: task, to: .cancelled, at: at)
            }
            if task.state == .awaitingReview, task.pr?.isTerminal == true {
                let transitioned = transition(task: task, to: .done, at: at)
                return (transitioned.0, transitioned.1 + [.cleanupWorkspace(task: transitioned.0)])
            }
            return (task, [])
        case let .userRetry(taskID, at):
            guard taskID == task.id, task.state == .failed || task.state == .cancelled
                || task.state == .awaitingReview
            else {
                return (task, [])
            }
            var next = task
            next.isBlocked = false
            next.lastError = nil
            return transition(task: next, to: .queued, at: at)
        case let .userCancel(taskID, at):
            guard taskID == task.id, !task.state.isTerminal else {
                return (task, [])
            }
            let transitioned = transition(task: task, to: .cancelled, at: at)
            var commands = transitioned.1
            if task.state.isActive {
                commands.insert(.killAgent(task: task), at: 0)
            }
            return (transitioned.0, commands)
        }
    }

    private static func acceptsAgentStop(from state: FleetTaskState) -> Bool {
        switch state {
        case .launching, .running, .needsInput, .stalled:
            true
        case .queued, .provisioning, .retryBackoff, .awaitingReview, .done, .failed,
             .cancelled:
            false
        }
    }

    private static func startAttempt(
        task: FleetTask,
        command: (FleetTask, Int) -> FleetCommand,
        at: Date
    ) -> (FleetTask, [FleetCommand]) {
        var next = task
        next.attempts += 1
        next.isBlocked = false
        next.lastError = nil
        let transitioned = transition(task: next, to: .launching, at: at)
        guard transitioned.0.state == .launching else {
            return (task, [])
        }
        return (transitioned.0, [command(transitioned.0, transitioned.0.attempts)])
    }

    private static func retryOrFail(
        task: FleetTask,
        config: FleetSupervisionConfig,
        at: Date,
        killAgent: Bool
    ) -> (FleetTask, [FleetCommand]) {
        let maxAttempts = max(0, config.maxAttempts)
        let canRetry = task.attempts < maxAttempts
        let targetState: FleetTaskState = canRetry ? .retryBackoff : .failed
        var next = task
        next.isBlocked = false
        let transitioned = transition(task: next, to: targetState, at: at)
        guard transitioned.0.state == targetState else {
            return (task, [])
        }

        var commands: [FleetCommand] = []
        if killAgent {
            commands.append(.killAgent(task: task))
        }
        if canRetry {
            let delay = FleetBackoff.delayMS(
                attempt: max(task.attempts, 1),
                maxMS: config.maxRetryBackoffMS
            )
            commands.append(.scheduleBackoff(taskID: task.id, delayMS: delay))
        }
        return (transitioned.0, commands)
    }

    private static func transition(
        task: FleetTask,
        to state: FleetTaskState,
        at: Date
    ) -> (FleetTask, [FleetCommand]) {
        guard FleetTaskState.canTransition(from: task.state, to: state) else {
            return (task, [])
        }

        var next = task
        next.state = state
        next.updatedAt = at
        next.lastActivityAt = at
        return (next, [])
    }
}
