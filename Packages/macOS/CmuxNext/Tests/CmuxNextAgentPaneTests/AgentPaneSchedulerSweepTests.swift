import AppKit
@testable import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// p06-scheduler-331, the sweep of CmuxNextAgentPane's second half, FreeTier and Approvals: one case per migrated
/// owner class (plans/cmux-next/chrome-parity/p06-scheduler.md, rule 9).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AgentPaneSchedulerSweepTests {
    final class Count { var value = 0 }

    @Observable final class Switch { var on = true }

    /// R-hop: the transport's default pacer flushes in one posted `visible` task of the transport's scheduler, never
    /// in the call that scheduled it (an unclassed main-actor Task flushed outside the board before).
    @Test func theNextTurnPacerFlushesInAPostedVisibleTask() {
        let turns = Turns()
        let work = MainWorkScheduler.testing(performTurn: { turns.queue($0) }) { _ in Link() }
        let pacer = AgentPaneNextTurnPacer(mainWork: work)
        let flushes = Count()
        let ran = Ran()
        pacer.schedule {
            flushes.value += 1
            ran.task = work.budget.board.running
            return AgentPaneFlush(delivered: true, more: false)
        }
        pacer.schedule { AgentPaneFlush(delivered: false, more: false) }  // coalesced: one flush is already posted
        #expect(flushes.value == 0, "the pacer flushed in the call")
        #expect(work.postedCount(.visible) == 1)
        turns.runAll()
        #expect(flushes.value == 1)
        #expect(ran.task?.workClass == .visible)
        #expect(ran.task?.owner == "agentPane.transport.nextTurnFlush")
    }

    /// The transport and the shell take the model's scheduler, and the shell's deadlines (a read's wait, Stop's
    /// escalation, the drain after exit) are `visible` deadlines on it: the page waits on each (rule 6).
    @Test func theModelsOwnersShareItsSchedulerAndTheShellsDeadlinesAreVisible() {
        let deadlines = MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))
        let model = AgentPaneModel(host: MockAgentPaneHost(), deadlines: deadlines)
        #expect(model.transport.mainWork === deadlines.work)
        let run = AgentPaneShell.Run(pid: 0, deadlines: deadlines)
        #expect(run.escalation.workClass == .visible)
        #expect(run.drain.workClass == .visible)
    }

    /// R-obs, ServiceObservation (rule 3): the suggested-tasks switch reaches the next daemon's flag while no page
    /// shows, in one posted task of the scheduler, not on a hidden page's turn.
    @Test func theSuggestedTasksSwitchReachesTheDaemonFlagWithNoPage() {
        let turns = Turns()
        let work = MainWorkScheduler.testing(performTurn: { turns.queue($0) }) { _ in Link() }
        let tasks = AgentPaneSuggestedTasks()
        let setting = Switch()
        tasks.follow(on: work)
        tasks.setting = { setting.on }
        #expect(AgentPaneSuggestedTasks.forNextDaemon.isOn)
        setting.on = false
        turns.runAll()
        #expect(!AgentPaneSuggestedTasks.forNextDaemon.isOn, "the change did not reach the daemon flag")
        tasks.setting = { true }
    }

    /// R-timer, a race (the Deadline helper): a completion shell that runs past its limit answers `timedOut` at the
    /// limit, and its process group is killed.
    @Test func aCompletionShellPastItsLimitTimesOut() async throws {
        let launcher = ChildProcessLauncher(label: "com.cmuxterm.next.child-launcher.test-complete-timeout", priority: .userBlocking)
        let started = ContinuousClock.now
        await #expect(throws: AgentPaneShellCompletion.Failure.timedOut) {
            _ = try await CompletionProcess.run(path: "/bin/sh", arguments: ["/bin/sh", "-c", "sleep 30"],
                                                environment: ["PATH": "/usr/bin:/bin"], folder: NSTemporaryDirectory(),
                                                timeout: .milliseconds(200), launcher: launcher)
        }
        #expect(ContinuousClock.now - started < .seconds(10), "the limit did not end the wait")
    }

    @MainActor final class Ran {
        var task: MainTaskBoard.Task?
    }

    /// The scheduler's posted turns, run by hand.
    @MainActor final class Turns {
        private var pending: [@MainActor () -> Void] = []

        func queue(_ turn: @escaping @MainActor () -> Void) { pending.append(turn) }

        func runAll() {
            while !pending.isEmpty { pending.removeFirst()() }
        }
    }

    @MainActor final class Link: FrameLink {
        var isPaused = false
        func invalidate() {}
    }
}
