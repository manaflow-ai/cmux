import Foundation

/// Where a host menu tracks from. `NSMenu.popUp` runs the menu's tracking loop inline; inside a
/// main-queue job (a main-actor Task, a `DispatchQueue.main` block) the main queue does not drain
/// until the menu closes, so every main-actor job queued while it is open waits, and the click that
/// closes it waits for them (Leo, 2026-10-29: "clicking out of a fucking context menu is sometimes
/// slow as fucking balls"). From a run-loop callout (``MainRunLoopBlock``) the tracking loop keeps
/// the main queue running.
enum PageMenuCallout {
    /// True when the caller runs inside a main run loop block callout.
    static var isRunLoopBlock: Bool {
        Thread.callStackSymbols.contains { $0.contains("__CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__") }
    }

    /// Runs main run loop passes (and lets main-actor jobs run between them) until `done` holds or
    /// `timeout` passes on a `ContinuousClock`: a test's main-actor job is not itself a run-loop pass,
    /// so a block queued on the main run loop runs only in such a pass. The bound is time, not a pass
    /// count, so a slow CI host gets the same wall-clock allowance as a fast one; the caller's
    /// `#expect` on `done` reports a run that never got there.
    @MainActor static func drain(timeout: Duration = .seconds(5), until done: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !done(), clock.now < deadline {
            runPass()
            await Task.yield()
        }
    }

    /// One pass of the main run loop (CFRunLoopRunInMode is unavailable from async code).
    @MainActor private static func runPass() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {}
        _ = CFRunLoopRunInMode(.defaultMode, 0.01, false)
    }
}
