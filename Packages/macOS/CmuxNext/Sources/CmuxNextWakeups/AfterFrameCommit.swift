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
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            MainActor.assumeIsolated(work) // main-proof: an observer of the main run loop
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
