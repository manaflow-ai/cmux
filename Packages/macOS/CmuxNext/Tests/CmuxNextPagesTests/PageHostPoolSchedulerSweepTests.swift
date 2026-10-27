import AppKit
@testable import CmuxNextPages
@testable import CmuxNextWakeups
import Testing

/// The CmuxNextPages sweep (plans/cmux-next/chrome-parity/p06-scheduler.md, task p06-scheduler-336, rule 9): the
/// pool's spare is work nobody sees, so its idle deadline and every step of its build are background tasks on the
/// app's scheduler. A build step never runs in the turn that asked for it; it waits for a frame in which background
/// work may run, so input and visible work go first (Chrome's kBestEffort,
/// content/browser/scheduler/browser_task_queues.h).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PageHostPoolSchedulerSweepTests {
    @Test func theSpareBuildsOnlyInBackgroundTasksOfTheInjectedScheduler() async {
        let rig = LifecycleDeadlineRig()
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let memory = PageTestMemory()
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(memory: memory.coordinator, policy: policy, deadlines: rig.scheduler,
                                activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare() }
        pool.follow(window)
        pool.noteLikely()
        #expect(pool.timer.isScheduled, "a likely page armed no build")
        #expect(pool.timer.workClass == .background, "the spare's build deadline is not background work")
        #expect(!pool.isBuilding, "the build started before its deadline")

        // The deadline's wake posts the build's start; the frame runs it, and the build's first step waits.
        rig.fire()
        await Self.yield(until: { pool.spans.contains { $0.name == "pool.makeSpare.configure" } })
        #expect(pool.isBuilding)
        #expect(!pool.spans.contains { $0.name == "pool.makeSpare.create" }, "the build made its page in the turn it started")
        #expect(rig.work.postedCount(.background) == 1, "the build's next step is not one posted background task")

        // One frame runs that task, and the page is made after it.
        rig.fire(movingTime: false)
        await Self.yield(until: { pool.spans.contains { $0.name == "pool.makeSpare.create" } })
        #expect(pool.spans.contains { $0.name == "pool.makeSpare.create" }, "the posted step never ran in its frame")

        // Nothing likely any more: the next step closes the page it made and ends the build.
        pool.isLikely = false
        rig.fire(movingTime: false)
        await Self.yield(until: { !pool.isBuilding })
        #expect(!pool.isBuilding, "the build did not end")
        #expect(pool.spareHost == nil)
    }

    /// Main-actor turns until `done` (at most 200): a resumed build runs in one of them.
    private static func yield(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }
}
