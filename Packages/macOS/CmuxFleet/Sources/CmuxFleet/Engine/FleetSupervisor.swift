import Foundation

/// Reduces one Fleet task snapshot with one deterministic supervision signal.
public struct FleetSupervisor: Sendable {
    /// The supervision limits used for retry decisions.
    public var config: FleetSupervisionConfig

    /// Creates a deterministic Fleet supervisor reducer.
    /// - Parameter config: The supervision limits used for retry decisions.
    public init(config: FleetSupervisionConfig = FleetSupervisionConfig()) {
        self.config = config
    }

    /// Applies a signal to a task without performing I/O or reading the clock.
    /// - Parameters:
    ///   - task: The current task snapshot.
    ///   - signal: The deterministic signal to apply.
    /// - Returns: The next task snapshot and imperative commands for the engine.
    public func reduce(
        task: FleetTask,
        signal: FleetSignal
    ) -> (FleetTask, [FleetCommand]) {
        switch signal {
        case .sourceSync:
            return (task, [])
        case let .dispatched(taskID, at):
            guard taskID == task.id, task.state == .queued else {
                return (task, [])
            }
            let transitioned = transition(task: task, to: .provisioning, at: at)
            guard transitioned.0.state == .provisioning else {
                return (task, [])
            }
            return (transitioned.0, transitioned.1 + [
                .provisionWorkspace(task: transitioned.0),
            ])
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
        case let .agentSessionStarted(taskID, attempt, sessionID, pid, at):
            guard taskID == task.id, attempt == task.attempts, task.state == .launching else {
                return (task, [])
            }
            _ = sessionID
            _ = pid
            return transition(task: task, to: .running, at: at)
        case let .activity(taskID, attempt, at):
            guard taskID == task.id, attempt == task.attempts, !task.state.isTerminal else {
                return (task, [])
            }
            var next = task
            next.lastActivityAt = at
            next.updatedAt = at
            return (next, [])
        case let .blockingItemReceived(taskID, attempt, at):
            guard taskID == task.id, attempt == task.attempts, task.state == .running else {
                return (task, [])
            }
            var next = task
            next.isBlocked = true
            let transitioned = transition(task: next, to: .needsInput, at: at)
            return (transitioned.0, transitioned.1 + [
                .postNotification(taskID: task.id, kind: .needsInput),
            ])
        case let .blockingItemResolved(taskID, attempt, at):
            guard taskID == task.id, attempt == task.attempts, task.state == .needsInput else {
                return (task, [])
            }
            var next = task
            next.isBlocked = false
            return transition(task: next, to: .running, at: at)
        case let .agentStopped(taskID, attempt, at):
            guard taskID == task.id, attempt == task.attempts, acceptsAgentStop(from: task.state) else {
                return (task, [])
            }
            if task.pr?.isTerminal == true {
                let transitioned = transition(task: task, to: .done, at: at)
                return (transitioned.0, transitioned.1 + [.cleanupWorkspace(task: transitioned.0)])
            }
            if task.pr != nil {
                return transition(task: task, to: .awaitingReview, at: at)
            }
            return retryOrFail(task: task, at: at, killAgent: false)
        case let .pidExited(taskID, attempt, at):
            guard taskID == task.id, attempt == task.attempts,
                  task.state == .launching || task.state == .running || task.state == .needsInput
            else {
                return (task, [])
            }
            return retryOrFail(task: task, at: at, killAgent: false)
        case let .promptIdleObserved(taskID, attempt, at):
            guard taskID == task.id, attempt == task.attempts, task.state == .running else {
                return (task, [])
            }
            return retryOrFail(task: task, at: at, killAgent: false)
        case let .stallTimeout(taskID, attempt, at):
            guard taskID == task.id, attempt == task.attempts,
                  task.state == .launching || task.state == .running || task.state == .needsInput
            else {
                return (task, [])
            }
            return retryOrFail(task: task, at: at, killAgent: true)
        case let .backoffElapsed(taskID, attempt, at):
            guard taskID == task.id, task.state == .retryBackoff, attempt == task.attempts else {
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
            if task.state == .retryBackoff || task.state == .failed {
                let target: FleetTaskState = pr.isTerminal ? .done : .awaitingReview
                let transitioned = transition(task: next, to: target, at: at)
                guard transitioned.0.state == target else {
                    return (task, [])
                }
                let commands = target == .done
                    ? transitioned.1 + [.cleanupWorkspace(task: transitioned.0)]
                    : transitioned.1
                return (transitioned.0, commands)
            }
            next.updatedAt = at
            return (next, [])
        case let .sourceReachedTerminalState(taskID, at):
            guard taskID == task.id else {
                return (task, [])
            }
            if task.state == .awaitingReview, task.pr?.isTerminal == true {
                let transitioned = transition(task: task, to: .done, at: at)
                return (transitioned.0, transitioned.1 + [.cleanupWorkspace(task: transitioned.0)])
            }
            guard !task.state.isTerminal else {
                return (task, [])
            }
            return cancelForTerminalSource(task: task, at: at)
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

    private func acceptsAgentStop(from state: FleetTaskState) -> Bool {
        switch state {
        case .launching, .running, .needsInput, .stalled:
            true
        case .queued, .provisioning, .retryBackoff, .awaitingReview, .done, .failed,
             .cancelled:
            false
        }
    }

    private func startAttempt(
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
        return (
            transitioned.0,
            transitioned.1 + [command(transitioned.0, transitioned.0.attempts)]
        )
    }

    private func retryOrFail(
        task: FleetTask,
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
            let delay = FleetBackoff(maxMS: config.maxRetryBackoffMS)
                .delayMS(attempt: max(task.attempts, 1))
            commands.append(.scheduleBackoff(taskID: task.id, attempt: task.attempts, delayMS: delay))
        }
        return (transitioned.0, commands)
    }

    private func cancelForTerminalSource(
        task: FleetTask,
        at: Date
    ) -> (FleetTask, [FleetCommand]) {
        let transitioned = transition(task: task, to: .cancelled, at: at)
        guard transitioned.0.state == .cancelled else {
            return (task, [])
        }

        var commands = transitioned.1
        if task.state.isActive {
            commands.insert(.killAgent(task: task), at: 0)
        }
        commands.append(.cleanupWorkspace(task: transitioned.0))
        return (transitioned.0, commands)
    }

    private func transition(
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
        let commands: [FleetCommand] = task.state == .retryBackoff && state != .retryBackoff
            ? [.cancelBackoff(taskID: task.id)]
            : []
        return (next, commands)
    }
}
