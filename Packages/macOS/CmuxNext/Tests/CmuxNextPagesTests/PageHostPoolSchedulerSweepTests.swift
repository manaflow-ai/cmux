import AppKit
@testable import CmuxNextPages
@testable import CmuxNextWakeups
import Testing

/// The CmuxNextPages sweep (plans/cmux-next/chrome-parity/p06-scheduler.md, task p06-scheduler-336, rule 9): the
/// pool's spare is work nobody sees, so its idle deadline and every step of its build run inside background tasks on
/// the app's scheduler. A build step never runs in the turn that asked for it, nor in an unattributed resume after its
/// task: it runs in the body of its own task, in a frame in which background work may run, so input and visible work
/// go first and the board charges the step to its owner (Chrome's kBestEffort,
/// content/browser/scheduler/browser_task_queues.h).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PageHostPoolSchedulerSweepTests {
    /// The task the board showed running when the pool measured a step; nil: none ran it.
    private final class Steps {
        var ranIn: [String: MainTaskBoard.Task?] = [:]

        func expectBackground(_ span: String, owner: String) {
            let task = ranIn[span].flatMap { $0 }
            #expect(task?.workClass == .background, "\(span) ran outside a background task")
            #expect(task?.owner == owner, "\(span) ran in \(task?.owner ?? "no task"), not \(owner)")
        }
    }

    @Test func eachStepOfTheSpareBuildRunsInsideABackgroundTaskOfTheInjectedScheduler() async {
        let rig = LifecycleDeadlineRig()
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let memory = PageTestMemory()
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(memory: memory.coordinator, policy: policy, deadlines: rig.scheduler,
                                activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare() }
        let steps = Steps()
        pool.onSpan = { name, _ in steps.ranIn[name] = rig.work.board.running }
        pool.follow(window)
        pool.noteLikely()
        #expect(pool.timer.isScheduled, "a likely page armed no build")
        #expect(pool.timer.workClass == .background, "the spare's build deadline is not background work")
        #expect(!pool.isBuilding, "the build started before its deadline")

        // The deadline's wake posts its action, and the frame runs it: the recipe is made in that background task,
        // and the next step is one posted background task, not run in this turn.
        rig.fire()
        steps.expectBackground("pool.makeSpare.configure", owner: "PageHostPool.build")
        #expect(pool.isBuilding)
        await Self.yield(until: { rig.work.postedCount(.background) == 1 })
        #expect(rig.work.postedCount(.background) == 1, "the build's next step is not one posted background task")
        #expect(steps.ranIn["pool.makeSpare.create"] == nil, "the build made its page in the turn it started")

        // One frame runs that task: the page is made inside it, and the park waits for a task of its own.
        rig.fire(movingTime: false)
        steps.expectBackground("pool.makeSpare.create", owner: "PageHostPool.build.create")
        await Self.yield(until: { rig.work.postedCount(.background) == 1 })
        #expect(steps.ranIn["pool.makeSpare.park"] == nil, "the build parked its page in the turn it made it")

        rig.fire(movingTime: false)
        steps.expectBackground("pool.makeSpare.park", owner: "PageHostPool.build.park")
        #expect(pool.spareHost != nil)
        await Self.yield(until: { rig.work.postedCount(.background) == 1 })

        // The spare went before its load step ran: that step loads nothing and ends the build, in its own task.
        pool.dropSpare()
        rig.fire(movingTime: false)
        await Self.yield(until: { !pool.isBuilding })
        #expect(!pool.isBuilding, "the build did not end")
        #expect(steps.ranIn["pool.makeSpare.load"] == nil, "the build loaded a spare it no longer has")
        #expect(pool.spareHost == nil)
    }

    /// Main-actor turns until `done` (at most 200): a resumed build runs in one of them.
    private static func yield(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }
}
