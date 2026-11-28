import CoreFoundation

/// Runs a block once, the next time the main run loop is about to sleep
/// (nothing else to do): a one-shot before-waiting observer ordered after
/// AppKit's display and the Core Animation commit, so the pending frame is
/// already on its way. It never wakes the loop and costs nothing once run.
///
/// ```swift
/// IdleOnce().schedule { palette.prepare(step: 0) }
/// ```
public struct IdleOnce: Sendable {
    public init() {}

    /// Runs `work` on the main thread the next time the main run loop is about to sleep. Call on the main thread.
    @MainActor
    public func schedule(_ work: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max - 1) { _, _ in
            MainActor.assumeIsolated { work() } // main-proof: the observer is added only to CFRunLoopGetMain() (below)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
    }
}
