import CmuxNextCompat
@testable import CmuxNextWakeups
import CoreFoundation
import Dispatch
import Foundation
import Testing

/// The priority-ordered main executor (plans/cmux-next/chrome-parity/p06-scheduler.md, task 202): main-actor jobs in
/// five FIFO classes chosen by task priority, run highest class first by one run-loop source pass that yields to
/// pending input. These tests drive a hook they never install (``MainExecutorHook/enqueue(priority:_:)`` and
/// ``MainExecutorHook/runPass()``, or a real main run loop through its source and observer). In the gate's run
/// (`CMUX_MAIN_EXECUTOR_HOOK=1 swift test`) the process's first scheduler installs it, and
/// ``runtimeJobsRunInOrderThroughTheInstalledHook()`` then requires it and checks real runtime jobs.
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
        #expect(hook.stats.ran(.visible) == 1)
        #expect(hook.stats.ran(.background) == 100)
        #expect(hook.stats.queued == 0)
    }

    /// The spec's mapping (p06-scheduler.md, task 202): userInitiated/high to visible, medium to automation,
    /// utility/low to background, background to idle; a job the main thread enqueues in an input turn is input,
    /// whatever its priority. No priority is the runtime's default, medium.
    @Test func prioritiesMapToClasses() {
        #expect(MainExecutorHook.workClass(priority: TaskPriority.high.rawValue, inInputTurn: false) == .visible)
        #expect(MainExecutorHook.workClass(priority: 0x21, inInputTurn: false) == .visible, "userInteractive")
        #expect(MainExecutorHook.workClass(priority: TaskPriority.medium.rawValue, inInputTurn: false) == .automation)
        #expect(MainExecutorHook.workClass(priority: 0, inInputTurn: false) == .automation, "no priority stated")
        #expect(MainExecutorHook.workClass(priority: TaskPriority.low.rawValue, inInputTurn: false) == .background)
        #expect(MainExecutorHook.workClass(priority: TaskPriority.background.rawValue, inInputTurn: false) == .idle)
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

    /// A pass runs only the jobs queued before it began: a job that a job enqueues waits for the next pass, even at a
    /// higher class than older queued jobs, which still run in this pass.
    @Test func jobsEnqueuedDuringAPassWaitForTheNext() {
        let hook = MainExecutorHook(yieldsToInput: { false })
        let ran = Ran()
        hook.enqueue(priority: TaskPriority.low.rawValue) {
            ran.names.append("first")
            hook.enqueue(priority: TaskPriority.high.rawValue) { ran.names.append("nested") }
        }
        hook.enqueue(priority: TaskPriority.low.rawValue) { ran.names.append("second") }
        hook.runPass()
        #expect(ran.names == ["first", "second"])
        #expect(hook.stats.queued == 1)
        hook.runPass()
        #expect(ran.names == ["first", "second", "nested"])
        #expect(hook.stats.queued == 0)
    }

    /// The real main run loop under a stream of main-actor jobs (each enqueues the next, as an agent's resumes do):
    /// the before-waiting and exit observers, where Core Animation commits, run between every two passes.
    @Test func runLoopObserversRunBetweenPassesUnderAStreamOfJobs() {
        let hook = MainExecutorHook(yieldsToInput: { false })
        hook.attachSource()
        defer { hook.detachSource() }
        let log = Ran()
        // Where Core Animation's commit observer sits: these stages, order 2000000.
        let commit = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: 2_000_000) { _ in log.names.append("commit") }
        defer { commit.invalidate() }
        let count = 20
        Self.stream(0, of: count, on: hook, log: log)
        var runs = 0
        while log.names.filter({ $0.hasPrefix("job") }).count < count, runs < 400 {
            _ = CFRunLoopRunInMode(.defaultMode, 0.005, false)
            runs += 1
        }
        let jobs = log.names.indices.filter { log.names[$0].hasPrefix("job") }
        #expect(jobs.count == count)
        for (earlier, later) in zip(jobs, jobs.dropFirst()) {
            #expect(log.names[(earlier + 1) ..< later].contains("commit"), "no commit between \(log.names[earlier]) and \(log.names[later])")
        }
    }

    /// Pending input stops a pass after its first job, before any job below input; input jobs still run, and the rest
    /// waits for a pass after the input.
    @Test func passYieldsToPendingInput() {
        let input = PendingInput()
        let clock = HookClock()
        let hook = MainExecutorHook(yieldsToInput: { input.pending }, clock: { clock.now })
        let ran = Ran()
        for index in 0 ..< 3 {
            hook.enqueue(priority: TaskPriority.medium.rawValue) { ran.names.append("medium \(index)") }
        }
        hook.noteInputTurn(began: true)
        hook.enqueue(priority: TaskPriority.low.rawValue) { ran.names.append("input") }
        hook.noteInputTurn(began: false)
        input.pending = true
        hook.runPass()
        #expect(ran.names == ["input"], "the first job always runs: progress")
        clock.advance(MainExecutorHook.inputCheckNanos)
        hook.runPass()
        #expect(ran.names == ["input", "medium 0"], "one job per pass while input waits")
        #expect(hook.stats.yields == 2)
        input.pending = false
        clock.advance(MainExecutorHook.inputCheckNanos)
        hook.runPass()
        #expect(ran.names == ["input", "medium 0", "medium 1", "medium 2"])
        #expect(hook.stats.queued == 0)
    }

    /// The setting turns it off: nothing is installed while neither the feature nor the environment asks, and `0` in
    /// the environment wins over the feature.
    @Test func settingOffInstallsNothing() {
        #expect(!MainExecutorHook.isRequested(feature: false, environment: [:]))
        #expect(MainExecutorHook.isRequested(feature: true, environment: [:]))
        #expect(!MainExecutorHook.isRequested(feature: true, environment: [MainExecutorHook.environmentKey: "0"]))
        #expect(MainExecutorHook.isRequested(feature: false, environment: [MainExecutorHook.environmentKey: "1"]))
        guard !Self.gateRun else { return } // the gate's run: every scheduler asks for the hook
        let work = MainWorkScheduler.testing { _ in HookFakeLink() }
        #expect(work.mainExecutorHookState == .off)
        #expect(work.installMainExecutorHook(requested: false) == .off)
        #expect(work.mainExecutorHook == nil)
    }

    /// With the hook installed (the gate's run): a runtime task's main-actor jobs go through it, in its class, in
    /// order, on the main queue's thread with the main actor's isolation (`preconditionIsolated`, `dispatchPrecondition`).
    /// The test waits through a continuation, not the task's value, so the task is not escalated to the test's
    /// priority.
    @Test func runtimeJobsRunInOrderThroughTheInstalledHook() async throws {
        guard Self.gateRun else { return } // off: the main dispatch queue runs them
        _ = MainWorkScheduler.testing { _ in HookFakeLink() } // the process's first scheduler installs it
        let hook = try #require(MainExecutorHook.installed, "CMUX_MAIN_EXECUTOR_HOOK=1, but the hook is missing or busy")
        let ran = Ran()
        let before = hook.stats.ran(.background)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            // main-hop-allow: the test makes runtime main-actor jobs on purpose, to see the hook run them
            Task(priority: .low) { @MainActor in
                for index in 0 ..< 5 {
                    MainActor.preconditionIsolated("a runtime main-actor job ran off the main actor's executor")
                    ran.names.append("step \(index)")
                    dispatchPrecondition(condition: .onQueue(.main))
                    await Task.yield()
                }
                done.resume()
            }
        }
        #expect(ran.names == (0 ..< 5).map { "step \($0)" })
        #expect(hook.stats.ran(.background) >= before + 6, "the task's first job and its 5 resumes, as utility work")
    }

    /// The process was launched for the gate's run.
    private static var gateRun: Bool { ProcessInfo.processInfo.environment[MainExecutorHook.environmentKey] == "1" }

    /// Step `index` of a chain: each step runs as one job and queues the next one, at a higher priority from step 2
    /// on (an awaiting task escalated it).
    private static func step(_ index: Int, of count: Int, on hook: MainExecutorHook, ran: Ran) {
        let priority = index >= 2 ? TaskPriority.high : TaskPriority.medium
        hook.enqueue(priority: priority.rawValue) {
            ran.names.append("step \(index)")
            if index + 1 < count { step(index + 1, of: count, on: hook, ran: ran) }
        }
    }

    /// Job `index` of a stream: each job enqueues the next one at once.
    private static func stream(_ index: Int, of count: Int, on hook: MainExecutorHook, log: Ran) {
        hook.enqueue(priority: TaskPriority.low.rawValue) {
            log.names.append("job \(index)")
            if index + 1 < count { stream(index + 1, of: count, on: hook, log: log) }
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
