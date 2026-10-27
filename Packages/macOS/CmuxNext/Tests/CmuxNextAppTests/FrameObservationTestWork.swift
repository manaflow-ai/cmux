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
