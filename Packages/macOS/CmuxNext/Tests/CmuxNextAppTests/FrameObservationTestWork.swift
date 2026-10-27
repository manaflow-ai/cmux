import CmuxNextWakeups
import Foundation

/// A main-thread scheduler with no display link (tests): a view's ``FrameObservation`` applies a
/// change on the next main run loop pass (``runMainLoop(until:)``), as with no frames running.
@MainActor func linklessMainWork() -> MainWorkScheduler {
    MainWorkScheduler.testing { _ in nil }
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
