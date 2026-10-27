public import CmuxNextCompat
import CoreFoundation

/// Runs main-actor work once this run-loop pass committed its frame: a one-shot main run loop
/// observer after every other observer of the pass (Core Animation's commit runs before it), then
/// a wakeup so what the work changed commits in the next pass. For work that must not delay the
/// frame a key asked for, yet must follow it at once (PL-cef-tab: a new tab's page and its
/// Chromium window after the tab's first frame). It never polls and never sleeps.
///
/// ```swift
/// AfterFrameCommit().run { [weak self] in self?.createDeferredBrowsers() }
/// ```
public struct AfterFrameCommit: Sendable {
    public init() {}

    /// Runs `work` on the main thread after the current pass's commit. Call on the main thread.
    public func run(_ work: @escaping @MainActor () -> Void) {
        // The frame commit point has no async-native signal: `MainRunLoopObserver` is the seam.
        MainRunLoopObserver.once(activities: .beforeWaiting, order: .max) {
            work()
            // What `work` changed is in a new implicit transaction: wake the run loop so the next
            // pass commits it instead of sleeping until unrelated input.
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// Runs `work` on the main thread after every pass's commit, until the returned observer is
    /// released or invalidated: after Core Animation's commit both before the wait and at the run
    /// loop's exit (a pass that polls and never waits commits only there). When `work` returns true
    /// (it changed something), the run loop wakes so the next pass commits that. Capture the owner
    /// weakly in `work`.
    ///
    /// ```swift
    /// drain = AfterFrameCommit().everyPass { [weak gate] in gate?.forwardOldest() ?? false }
    /// ```
    public func everyPass(_ work: @escaping @MainActor () -> Bool) -> MainRunLoopObserver {
        MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: .max) { _ in
            if work() { CFRunLoopWakeUp(CFRunLoopGetMain()) }
        }
    }
}
