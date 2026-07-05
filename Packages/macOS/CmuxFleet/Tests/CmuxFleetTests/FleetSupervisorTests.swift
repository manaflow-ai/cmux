import CmuxFleet
import Foundation
import Testing

enum SupervisorSignalKind: CaseIterable {
    case sourceSync
    case dispatched
    case provisioned
    case provisionFailed
    case agentSessionStarted
    case activity
    case blockingItemReceived
    case blockingItemResolved
    case agentStopped
    case pidExited
    case promptIdleObserved
    case stallTimeout
    case backoffElapsed
    case workspaceClosed
    case prChanged
    case sourceReachedTerminalState
    case userRetry
    case userCancel

    func signal(at date: Date) -> FleetSignal {
        switch self {
        case .sourceSync:
            .sourceSync(tasks: [FleetTestSupport.task()], at: date)
        case .dispatched:
            .dispatched(taskID: FleetTestSupport.taskID, at: date)
        case .provisioned:
            .provisioned(taskID: FleetTestSupport.taskID, path: "/tmp/task", isBrandNew: true, at: date)
        case .provisionFailed:
            .provisionFailed(taskID: FleetTestSupport.taskID, message: "failed", at: date)
        case .agentSessionStarted:
            .agentSessionStarted(taskID: FleetTestSupport.taskID, sessionID: "session", pid: 42, at: date)
        case .activity:
            .activity(taskID: FleetTestSupport.taskID, at: date)
        case .blockingItemReceived:
            .blockingItemReceived(taskID: FleetTestSupport.taskID, at: date)
        case .blockingItemResolved:
            .blockingItemResolved(taskID: FleetTestSupport.taskID, at: date)
        case .agentStopped:
            .agentStopped(taskID: FleetTestSupport.taskID, at: date)
        case .pidExited:
            .pidExited(taskID: FleetTestSupport.taskID, at: date)
        case .promptIdleObserved:
            .promptIdleObserved(taskID: FleetTestSupport.taskID, at: date)
        case .stallTimeout:
            .stallTimeout(taskID: FleetTestSupport.taskID, at: date)
        case .backoffElapsed:
            .backoffElapsed(taskID: FleetTestSupport.taskID, attempt: 1, at: date)
        case .workspaceClosed:
            .workspaceClosed(taskID: FleetTestSupport.taskID, at: date)
        case .prChanged:
            .prChanged(
                taskID: FleetTestSupport.taskID,
                pr: FleetPullRequestStatus(number: 1, state: .open),
                at: date
            )
        case .sourceReachedTerminalState:
            .sourceReachedTerminalState(taskID: FleetTestSupport.taskID, at: date)
        case .userRetry:
            .userRetry(taskID: FleetTestSupport.taskID, at: date)
        case .userCancel:
            .userCancel(taskID: FleetTestSupport.taskID, at: date)
        }
    }

    func expectedState(from state: FleetTaskState) -> FleetTaskState {
        switch self {
        case .sourceSync, .activity, .prChanged:
            state
        case .dispatched:
            state == .queued ? .provisioning : state
        case .provisioned:
            state == .provisioning ? .launching : state
        case .provisionFailed:
            state == .provisioning ? .failed : state
        case .agentSessionStarted:
            state == .launching ? .running : state
        case .blockingItemReceived:
            state == .running ? .needsInput : state
        case .blockingItemResolved:
            state == .needsInput ? .running : state
        case .agentStopped:
            [.launching, .running, .needsInput, .stalled].contains(state) ? .retryBackoff : state
        case .pidExited:
            [.launching, .running, .needsInput].contains(state) ? .retryBackoff : state
        case .promptIdleObserved:
            state == .running ? .retryBackoff : state
        case .stallTimeout:
            [.launching, .running, .needsInput].contains(state) ? .retryBackoff : state
        case .backoffElapsed:
            state == .retryBackoff ? .launching : state
        case .workspaceClosed, .userCancel:
            state.isTerminal ? state : .cancelled
        case .sourceReachedTerminalState:
            state.isTerminal ? state : .cancelled
        case .userRetry:
            state == .failed || state == .cancelled || state == .awaitingReview ? .queued : state
        }
    }

    var mutatesWithoutStateChange: Bool {
        switch self {
        case .activity, .prChanged:
            true
        case .sourceSync, .dispatched, .provisioned, .provisionFailed, .agentSessionStarted,
             .blockingItemReceived, .blockingItemResolved, .agentStopped, .pidExited,
             .promptIdleObserved, .stallTimeout, .backoffElapsed, .workspaceClosed,
             .sourceReachedTerminalState, .userRetry, .userCancel:
            false
        }
    }
}

@Suite("FleetSupervisor")
struct FleetSupervisorTests {
    @Test func coversEverySignalAgainstEveryState() {
        for signalKind in SupervisorSignalKind.allCases {
            for state in FleetTaskState.allCases {
                let task = FleetTestSupport.task(state: state)
                let reduced = FleetSupervisor().reduce(
                    task: task,
                    signal: signalKind.signal(at: FleetTestSupport.eventDate)
                )

                #expect(reduced.0.state == signalKind.expectedState(from: state))
                if reduced.0.state == task.state, !signalKind.mutatesWithoutStateChange {
                    #expect(reduced.0 == task)
                    #expect(reduced.1.isEmpty)
                }
            }
        }
    }

    @Test func ignoresSignalsForOtherTasks() {
        let task = FleetTestSupport.task(state: .running)
        let signal = FleetSignal.pidExited(taskID: FleetTestSupport.otherTaskID, at: FleetTestSupport.eventDate)

        let reduced = FleetSupervisor().reduce(task: task, signal: signal)

        #expect(reduced.0 == task)
        #expect(reduced.1.isEmpty)
    }

    @Test func dispatchedMovesQueuedTaskToProvisioningAndCommandsProvisioning() {
        let task = FleetTestSupport.task(state: .queued)

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .dispatched(taskID: task.id, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0.state == .provisioning)
        #expect(reduced.1 == [.provisionWorkspace(task: reduced.0)])
    }

    @Test func provisionedLaunchesFirstAttemptAndRecordsPath() {
        let task = FleetTestSupport.task(state: .provisioning, attempts: 0)

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .provisioned(taskID: task.id, path: "/work/task", isBrandNew: true, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0.state == .launching)
        #expect(reduced.0.directoryPath == "/work/task")
        #expect(reduced.0.attempts == 1)
        guard case let .launchAgent(commandTask, attempt) = reduced.1.first else {
            Issue.record("expected launchAgent command")
            return
        }
        #expect(commandTask == reduced.0)
        #expect(attempt == 1)
    }

    @Test func blockingItemMovesRunningTaskToNeedsInputAndNotifies() {
        let task = FleetTestSupport.task(state: .running)

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .blockingItemReceived(taskID: task.id, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0.state == .needsInput)
        #expect(reduced.0.isBlocked)
        #expect(reduced.1 == [.postNotification(taskID: task.id, kind: .needsInput)])
    }

    @Test func blockingItemResolvedReturnsToRunning() {
        let task = FleetTestSupport.task(state: .needsInput, isBlocked: true)

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .blockingItemResolved(taskID: task.id, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0.state == .running)
        #expect(!reduced.0.isBlocked)
        #expect(reduced.1.isEmpty)
    }

    @Test func agentStopWithPullRequestAwaitsReview() {
        let task = FleetTestSupport.task(
            state: .running,
            pr: FleetPullRequestStatus(number: 12, state: .open)
        )

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .agentStopped(taskID: task.id, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0.state == .awaitingReview)
        #expect(reduced.1.isEmpty)
    }

    @Test func agentStopWithTerminalPullRequestCompletesAndCleansUp() {
        let task = FleetTestSupport.task(
            state: .running,
            pr: FleetPullRequestStatus(number: 12, state: .merged)
        )

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .agentStopped(taskID: task.id, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0.state == .done)
        #expect(reduced.1 == [.cleanupWorkspace(task: reduced.0)])
    }

    @Test func agentStopWithoutPullRequestSchedulesRetryOrFailsAtMaxAttempts() {
        let retrying = FleetTestSupport.task(state: .running, attempts: 1)
        let retry = FleetSupervisor().reduce(
            task: retrying,
            signal: .agentStopped(taskID: retrying.id, at: FleetTestSupport.eventDate)
        )
        #expect(retry.0.state == .retryBackoff)
        #expect(retry.1 == [.scheduleBackoff(taskID: retrying.id, attempt: 1, delayMS: 10_000)])

        let exhausted = FleetTestSupport.task(state: .running, attempts: 3)
        let failed = FleetSupervisor().reduce(
            task: exhausted,
            signal: .agentStopped(taskID: exhausted.id, at: FleetTestSupport.eventDate)
        )
        #expect(failed.0.state == .failed)
        #expect(failed.1.isEmpty)
    }

    @Test func crashSignalsRetryLaunchingRunningAndNeedsInputTasks() {
        let launching = FleetTestSupport.task(state: .launching, attempts: 1)
        let launchCrash = FleetSupervisor().reduce(
            task: launching,
            signal: .pidExited(taskID: launching.id, at: FleetTestSupport.eventDate)
        )
        #expect(launchCrash.0.state == .retryBackoff)
        #expect(launchCrash.1 == [.scheduleBackoff(taskID: launching.id, attempt: 1, delayMS: 10_000)])

        let running = FleetTestSupport.task(state: .running, attempts: 2)
        let crashed = FleetSupervisor().reduce(
            task: running,
            signal: .pidExited(taskID: running.id, at: FleetTestSupport.eventDate)
        )
        #expect(crashed.0.state == .retryBackoff)
        #expect(crashed.1 == [.scheduleBackoff(taskID: running.id, attempt: 2, delayMS: 20_000)])

        let needsInputCrashTask = FleetTestSupport.task(state: .needsInput, attempts: 2)
        let needsInputCrash = FleetSupervisor().reduce(
            task: needsInputCrashTask,
            signal: .pidExited(taskID: needsInputCrashTask.id, at: FleetTestSupport.eventDate)
        )
        #expect(needsInputCrash.0.state == .retryBackoff)
        #expect(needsInputCrash.1 == [
            .scheduleBackoff(taskID: needsInputCrashTask.id, attempt: 2, delayMS: 20_000),
        ])

        let needsInput = FleetTestSupport.task(state: .needsInput, attempts: 2)
        let ignored = FleetSupervisor().reduce(
            task: needsInput,
            signal: .promptIdleObserved(taskID: needsInput.id, at: FleetTestSupport.eventDate)
        )
        #expect(ignored.0 == needsInput)
        #expect(ignored.1.isEmpty)
    }

    @Test func stallTimeoutKillsThenRetriesOrFails() {
        let launching = FleetTestSupport.task(state: .launching, attempts: 1)
        let launchingTimeout = FleetSupervisor().reduce(
            task: launching,
            signal: .stallTimeout(taskID: launching.id, at: FleetTestSupport.eventDate)
        )
        #expect(launchingTimeout.0.state == .retryBackoff)
        #expect(launchingTimeout.1 == [
            .killAgent(task: launching),
            .scheduleBackoff(taskID: launching.id, attempt: 1, delayMS: 10_000),
        ])

        let task = FleetTestSupport.task(state: .needsInput, attempts: 2, isBlocked: true)

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .stallTimeout(taskID: task.id, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0.state == .retryBackoff)
        #expect(!reduced.0.isBlocked)
        #expect(reduced.1 == [
            .killAgent(task: task),
            .scheduleBackoff(taskID: task.id, attempt: 2, delayMS: 20_000),
        ])

        let exhausted = FleetTestSupport.task(state: .running, attempts: 3)
        let failed = FleetSupervisor().reduce(
            task: exhausted,
            signal: .stallTimeout(taskID: exhausted.id, at: FleetTestSupport.eventDate)
        )
        #expect(failed.0.state == .failed)
        #expect(failed.1 == [.killAgent(task: exhausted)])
    }

    @Test func backoffElapsedRelaunchesWithNextAttempt() {
        let task = FleetTestSupport.task(state: .retryBackoff, attempts: 1)

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .backoffElapsed(taskID: task.id, attempt: 1, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0.state == .launching)
        #expect(reduced.0.attempts == 2)
        #expect(reduced.1.first == .cancelBackoff(taskID: task.id))
        guard case let .resendAgentCommand(commandTask, attempt) = reduced.1.last else {
            Issue.record("expected resendAgentCommand command")
            return
        }
        #expect(commandTask == reduced.0)
        #expect(attempt == 2)
    }

    @Test func staleBackoffElapsedIsIgnored() {
        let task = FleetTestSupport.task(state: .retryBackoff, attempts: 2)

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .backoffElapsed(taskID: task.id, attempt: 1, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0 == task)
        #expect(reduced.1.isEmpty)
    }

    @Test func terminalPullRequestCleansUpAwaitingReviewTask() {
        let task = FleetTestSupport.task(
            state: .awaitingReview,
            pr: FleetPullRequestStatus(number: 12, state: .open)
        )
        let terminalPR = FleetPullRequestStatus(number: 12, state: .merged)

        let changed = FleetSupervisor().reduce(
            task: task,
            signal: .prChanged(taskID: task.id, pr: terminalPR, at: FleetTestSupport.eventDate)
        )
        #expect(changed.0.state == .done)
        #expect(changed.0.pr == terminalPR)
        #expect(changed.1 == [.cleanupWorkspace(task: changed.0)])

        var withTerminalPR = task
        withTerminalPR.pr = terminalPR
        let sourceTerminal = FleetSupervisor().reduce(
            task: withTerminalPR,
            signal: .sourceReachedTerminalState(taskID: task.id, at: FleetTestSupport.eventDate)
        )
        #expect(sourceTerminal.0.state == .done)
        #expect(sourceTerminal.1 == [.cleanupWorkspace(task: sourceTerminal.0)])
    }

    @Test func sourceTerminalCancelsNonTerminalTasksAndCleansUp() {
        let task = FleetTestSupport.task(state: .queued)

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .sourceReachedTerminalState(taskID: task.id, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0.state == .cancelled)
        #expect(reduced.1 == [.cleanupWorkspace(task: reduced.0)])

        let running = FleetTestSupport.task(state: .running)
        let cancelledRunning = FleetSupervisor().reduce(
            task: running,
            signal: .sourceReachedTerminalState(taskID: running.id, at: FleetTestSupport.eventDate)
        )
        #expect(cancelledRunning.0.state == .cancelled)
        #expect(cancelledRunning.1 == [
            .killAgent(task: running),
            .cleanupWorkspace(task: cancelledRunning.0),
        ])

        let retryBackoff = FleetTestSupport.task(state: .retryBackoff, attempts: 2)
        let cancelledBackoff = FleetSupervisor().reduce(
            task: retryBackoff,
            signal: .sourceReachedTerminalState(taskID: retryBackoff.id, at: FleetTestSupport.eventDate)
        )
        #expect(cancelledBackoff.0.state == .cancelled)
        #expect(cancelledBackoff.1 == [
            .killAgent(task: retryBackoff),
            .cancelBackoff(taskID: retryBackoff.id),
            .cleanupWorkspace(task: cancelledBackoff.0),
        ])
    }

    @Test func userRetryResetsStateButKeepsAttempts() {
        let task = FleetTestSupport.task(state: .failed, attempts: 3, isBlocked: true, lastError: "failed")

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .userRetry(taskID: task.id, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0.state == .queued)
        #expect(reduced.0.attempts == 3)
        #expect(!reduced.0.isBlocked)
        #expect(reduced.0.lastError == nil)
        #expect(reduced.1.isEmpty)
    }

    @Test func userCancelCancelsNonTerminalTasksAndKillsActiveTasks() {
        let running = FleetTestSupport.task(state: .running)
        let cancelledRunning = FleetSupervisor().reduce(
            task: running,
            signal: .userCancel(taskID: running.id, at: FleetTestSupport.eventDate)
        )
        #expect(cancelledRunning.0.state == .cancelled)
        #expect(cancelledRunning.1 == [.killAgent(task: running)])

        let queued = FleetTestSupport.task(state: .queued)
        let cancelledQueued = FleetSupervisor().reduce(
            task: queued,
            signal: .userCancel(taskID: queued.id, at: FleetTestSupport.eventDate)
        )
        #expect(cancelledQueued.0.state == .cancelled)
        #expect(cancelledQueued.1.isEmpty)

        let done = FleetTestSupport.task(state: .done)
        let ignored = FleetSupervisor().reduce(
            task: done,
            signal: .userCancel(taskID: done.id, at: FleetTestSupport.eventDate)
        )
        #expect(ignored.0 == done)
        #expect(ignored.1.isEmpty)

        let retryBackoff = FleetTestSupport.task(state: .retryBackoff)
        let cancelledBackoff = FleetSupervisor().reduce(
            task: retryBackoff,
            signal: .userCancel(taskID: retryBackoff.id, at: FleetTestSupport.eventDate)
        )
        #expect(cancelledBackoff.0.state == .cancelled)
        #expect(cancelledBackoff.1 == [
            .killAgent(task: retryBackoff),
            .cancelBackoff(taskID: retryBackoff.id),
        ])
    }
}
