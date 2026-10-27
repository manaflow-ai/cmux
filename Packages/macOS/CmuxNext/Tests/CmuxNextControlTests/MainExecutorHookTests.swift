import CmuxNextCompat
import CmuxNextWakeups
import Dispatch
import Foundation
import Testing

/// The priority-ordered main executor (plans/cmux-next/chrome-parity/p06-scheduler.md, task 202): main-actor jobs in
/// five FIFO classes chosen by task priority, run highest class first by one run-loop source pass that yields to
/// pending input. These tests drive a hook they never install (``MainExecutorHook/enqueue(priority:_:)`` and
/// ``MainExecutorHook/runPass()``); the gate's run (`CMUX_MAIN_EXECUTOR_HOOK=1 swift test`) installs it for the whole
/// process, and then ``runtimeJobsRunInOrderThroughTheInstalledHook()`` checks real runtime jobs too.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainExecutorHookTests {
    /// 100 low jobs, then 1 high job: the high one runs first, and the low ones keep their order (Chrome's
    /// TaskQueueSelector: the highest class first, oldest first within a class).
    @Test func highJobRunsBeforeAHundredEarlierLowJobs() {
        let hook = MainExecutorHook(yieldsToInput: { false })
        let ran = Ran()
        for index in 0 ..< 100 {
            hook.enqueue(priority: TaskPriority.low.rawValue) { ran.names.append("low \(index)") }
        }
        hook.enqueue(priority: TaskPriority.high.rawValue) { ran.names.append("high") }
        hook.runPass()
        #expect(ran.names.first == "high")
        #expect(Array(ran.names.dropFirst()) == (0 ..< 100).map { "low \($0)" })
        #expect(hook.stats.ran(.userBlocking) == 1)
        #expect(hook.stats.ran(.automation) == 100)
        #expect(hook.stats.queued == 0)
    }

    /// Each priority maps to one class; a job the main thread enqueues in an input turn is input, whatever its
    /// priority.
    @Test func prioritiesMapToClasses() {
        #expect(MainExecutorHook.workClass(priority: TaskPriority.high.rawValue, inInputTurn: false) == .userBlocking)
        #expect(MainExecutorHook.workClass(priority: 0x21, inInputTurn: false) == .userBlocking, "userInteractive")
        #expect(MainExecutorHook.workClass(priority: TaskPriority.medium.rawValue, inInputTurn: false) == .visible)
        #expect(MainExecutorHook.workClass(priority: 0, inInputTurn: false) == .visible, "no priority stated")
        #expect(MainExecutorHook.workClass(priority: TaskPriority.low.rawValue, inInputTurn: false) == .automation)
        #expect(MainExecutorHook.workClass(priority: TaskPriority.background.rawValue, inInputTurn: false) == .background)
        #expect(MainExecutorHook.workClass(priority: TaskPriority.background.rawValue, inInputTurn: true) == .input)
    }

    /// A job started in an input turn runs as input: before high work queued earlier.
    @Test func jobEnqueuedInAnInputTurnRunsFirst() {
        let hook = MainExecutorHook(yieldsToInput: { false })
        let ran = Ran()
        hook.enqueue(priority: TaskPriority.high.rawValue) { ran.names.append("high") }
        hook.noteInputTurn(began: true)
        hook.enqueue(priority: TaskPriority.low.rawValue) { ran.names.append("input turn") }
        hook.noteInputTurn(began: false)
        hook.enqueue(priority: TaskPriority.low.rawValue) { ran.names.append("after the turn") }
        hook.runPass()
        #expect(ran.names == ["input turn", "high", "after the turn"])
        #expect(hook.stats.ran(.input) == 1)
    }

    /// One task's jobs keep their order: a task has one job queued at a time, and its class is FIFO, so a chain whose
    /// later steps are escalated still runs step by step, and jobs of one class never pass each other.
    @Test func oneTasksJobsKeepTheirOrder() {
        let hook = MainExecutorHook(yieldsToInput: { false })
        let ran = Ran()
        for index in 0 ..< 3 {
            hook.enqueue(priority: TaskPriority.medium.rawValue) { ran.names.append("other \(index)") }
        }
        Self.step(0, of: 4, on: hook, ran: ran)
        for _ in 0 ..< 5 { hook.runPass() }
        let steps = ran.names.filter { $0.hasPrefix("step") }
        #expect(steps == ["step 0", "step 1", "step 2", "step 3"])
        #expect(ran.names.filter { $0.hasPrefix("other") } == ["other 0", "other 1", "other 2"])
    }

    /// A pass runs only the jobs queued when it began: a job a job enqueues waits for the next pass (after the run
    /// loop's observers and the commit), even at a higher class.
    @Test func jobsEnqueuedDuringAPassWaitForTheNext() {
        let hook = MainExecutorHook(yieldsToInput: { false })
        let ran = Ran()
        hook.enqueue(priority: TaskPriority.low.rawValue) {
            ran.names.append("first")
            hook.enqueue(priority: TaskPriority.high.rawValue) { ran.names.append("nested") }
        }
        hook.runPass()
        #expect(ran.names == ["first"])
        #expect(hook.stats.queued == 1)
        hook.runPass()
        #expect(ran.names == ["first", "nested"])
    }

    /// Pending input stops a pass after its first job, before any job below input; input jobs still run, and the rest
    /// waits for a pass after the input.
    @Test func passYieldsToPendingInput() {
        let input = PendingInput()
        let clock = HookClock()
        let hook = MainExecutorHook(yieldsToInput: { input.pending }, clock: { clock.now })
        let ran = Ran()
        for index in 0 ..< 3 {
            hook.enqueue(priority: TaskPriority.medium.rawValue) { ran.names.append("visible \(index)") }
        }
        hook.noteInputTurn(began: true)
        hook.enqueue(priority: TaskPriority.low.rawValue) { ran.names.append("input") }
        hook.noteInputTurn(began: false)
        input.pending = true
        hook.runPass()
        #expect(ran.names == ["input"], "the first job always runs: progress")
        clock.advance(MainExecutorHook.inputCheckNanos)
        hook.runPass()
        #expect(ran.names == ["input", "visible 0"], "one job per pass while input waits")
        #expect(hook.stats.yields == 2)
        input.pending = false
        clock.advance(MainExecutorHook.inputCheckNanos)
        hook.runPass()
        #expect(ran.names == ["input", "visible 0", "visible 1", "visible 2"])
        #expect(hook.stats.queued == 0)
    }

    /// The setting turns it off: nothing is installed while neither the feature nor the environment asks, and `0` in
    /// the environment wins over the feature.
    @Test func settingOffInstallsNothing() {
        #expect(!MainExecutorHook.isRequested(feature: false, environment: [:]))
        #expect(MainExecutorHook.isRequested(feature: true, environment: [:]))
        #expect(!MainExecutorHook.isRequested(feature: true, environment: [MainExecutorHook.environmentKey: "0"]))
        #expect(MainExecutorHook.isRequested(feature: false, environment: [MainExecutorHook.environmentKey: "1"]))
        let work = MainWorkScheduler.testing { _ in HookFakeLink() }
        guard work.mainExecutorHookState == .off else { return } // the gate's run: this scheduler installed it first
        #expect(work.installMainExecutorHook(requested: false) == .off)
        #expect(work.mainExecutorHook == nil)
    }

    /// With the hook installed (the gate's run): a runtime task's main-actor jobs go through it, run in order, on the
    /// main queue's thread with the main actor's isolation (`assumeIsolated`, `dispatchPrecondition`).
    @Test func runtimeJobsRunInOrderThroughTheInstalledHook() async {
        guard let hook = MainExecutorHook.installed else { return } // off: the main dispatch queue runs them
        let ran = Ran()
        let before = hook.stats.ranByClass.reduce(0, +)
        // main-hop-allow: the test makes runtime main-actor jobs on purpose, to see the hook run them
        await Task(priority: .low) { @MainActor in
            for index in 0 ..< 5 {
                MainActor.assumeIsolated { ran.names.append("step \(index)") }
                dispatchPrecondition(condition: .onQueue(.main))
                await Task.yield()
            }
        }.value
        #expect(ran.names == (0 ..< 5).map { "step \($0)" })
        #expect(hook.stats.ranByClass.reduce(0, +) >= before + 5)
    }

    /// Step `index` of a chain: each step runs as one job and queues the next one, at a higher priority from step 2
    /// on (an awaiting task escalated it).
    private static func step(_ index: Int, of count: Int, on hook: MainExecutorHook, ran: Ran) {
        let priority = index >= 2 ? TaskPriority.high : TaskPriority.medium
        hook.enqueue(priority: priority.rawValue) {
            ran.names.append("step \(index)")
            if index + 1 < count { step(index + 1, of: count, on: hook, ran: ran) }
        }
    }
}

@MainActor private final class Ran {
    var names: [String] = []
}

@MainActor private final class PendingInput {
    var pending = false
}

private final class HookClock: Sendable {
    private let nanos = Mutex<UInt64>(1_000_000)
    var now: UInt64 { nanos.withLock { $0 } }
    func advance(_ by: UInt64) { nanos.withLock { $0 += by } }
}

@MainActor
private final class HookFakeLink: FrameLink {
    var isPaused = true
    func invalidate() {}
}
