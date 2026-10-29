import CmuxNextWakeups
import Foundation

/// A main-thread scheduler with no display link (tests): a view's ``FrameObservation`` applies a
/// change on the next main run loop pass (``runMainLoop(until:)``), as with no frames running.
@MainActor func linklessMainWork() -> MainWorkScheduler {
    MainWorkScheduler.testing { _ in nil }
}

/// A deadline placer on a ``linklessMainWork()`` scheduler (tests): the main thread's real wake-up queue;
/// its deadlines fire on the real clock and their actions run on the next main run loop pass.
@MainActor func linklessDeadlines() -> MainDeadlineScheduler {
    MainDeadlineScheduler(work: linklessMainWork())
}

/// A root node a person can see (tests): views on it update as they do on screen.
@MainActor func shownNode(_ name: String = "test.window") -> VisibilityNode {
    VisibilityNode(root: name, own: .visible)
}

/// Runs the main run loop until `done` holds, for at most 5 s; returns `done()`.
@MainActor func runMainLoop(until done: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: 5)
    while !done(), Date() < end {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    return done()
}

/// Runs the main run loop and lets the main actor's queued tasks run until `done` holds, for at most 5 s;
/// returns `done()`. For an async test whose work reaches main as a main-actor task (a `Task {}` made on main, an
/// `await` that resumes there) as well as a run-loop turn: ``runMainLoop(until:)`` never sees the first kind,
/// because the test body is itself a main-actor job, and a run loop nested in a main-queue job runs no other
/// main-queue job (CFRunLoop services the main dispatch queue only outside one). Each pass runs the run loop once,
/// then suspends the test so the main actor runs what is queued on it.
@MainActor func runMainLoopAndTasks(until done: () -> Bool) async -> Bool {
    let end = Date(timeIntervalSinceNow: 5)
    while !done(), Date() < end {
        runMainLoopPass(for: 0.01)
        await Task.yield()
    }
    return done()
}

/// Runs the main run loop and the main actor's queued tasks for `seconds` (an async test's wait for something
/// that must not happen, which a main-actor task could otherwise do only after the check).
@MainActor func runMainLoopAndTasks(for seconds: TimeInterval) async {
    let end = Date(timeIntervalSinceNow: seconds)
    repeat {
        runMainLoopPass(for: 0.01)
        await Task.yield()
    } while Date() < end
}

/// One main run loop pass of at most `seconds` (tests). It is a sync call, so an async test can make it:
/// `RunLoop.run(mode:before:)` itself is unavailable from async contexts.
@MainActor func runMainLoopPass(for seconds: TimeInterval) {
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: seconds))
}

/// A main-thread scheduler with no display link whose posted turns run as main-actor tasks (tests): an
/// async test sees a posted flush (a `ServiceObservation`'s, a `MainDeadline`'s action) after it yields,
/// with no main run loop pass.
@MainActor func taskTurnMainWork() -> MainWorkScheduler {
    MainWorkScheduler.testing(ledger: WakeupLedger(), performTurn: { turn in Task { @MainActor in turn() } }) { _ in nil }
}
