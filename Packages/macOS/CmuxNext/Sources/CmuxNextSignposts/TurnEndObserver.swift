import CoreFoundation

/// The seam between the main run loop and the always-on input intervals (``KeyFrameSignpost``,
/// ``InputFrameSignpost``): one repeating observer per owner at ``CommitBoundary/order``, one after Core Animation's
/// commit, that hands each turn's end (before waiting, on exit) and each wake to its owner on the main actor.
///
/// It is made once for its owner's life, as Chromium's message pump keeps its run-loop observers
/// (base/message_loop/message_pump_apple.mm, `PreWaitObserver`): no per-event install.
struct TurnEndObserver {
    /// Adds the observer to the main run loop's common modes. `reached` gets every callout; it returns false (its
    /// owner is gone) to remove the observer.
    @MainActor
    static func install(_ reached: @escaping @MainActor @Sendable (CFRunLoopActivity) -> Bool) {
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
            | CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, CommitBoundary.order) {
            firing, activity in
            // main-proof: the observer is added to the main run loop only (below).
            let keep = MainActor.assumeIsolated { reached(activity) }
            if !keep { CFRunLoopObserverInvalidate(firing) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }
}
