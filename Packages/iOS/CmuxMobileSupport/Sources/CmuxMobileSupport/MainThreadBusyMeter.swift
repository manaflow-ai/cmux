#if DEBUG && canImport(UIKit)
public import QuartzCore
import Foundation

/// DEBUG only. How long the main thread was awake (running anything: app
/// code, UIKit layout, Core Animation's commit) since the last `take()`,
/// from the main run loop's after-waiting and before-waiting activities.
/// The DEBUG frame traces read it once per display frame, to tell a long
/// frame the app's main thread caused from one it did not (the render
/// server, the simulator's keyboard).
@MainActor
public final class MainThreadBusyMeter {
    private var observer: CFRunLoopObserver?
    private var awakeSince: CFTimeInterval?
    private var busy: CFTimeInterval = 0
    /// The longest single awake span since the last `take()`.
    private var longest: CFTimeInterval = 0

    public init() {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max
        ) { [weak self] _, activity in
            // main-proof: the observer is added to the main run loop only
            // (CFRunLoopGetMain below), so its handler runs on the main thread.
            MainActor.assumeIsolated { self?.observe(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        awakeSince = CACurrentMediaTime()
    }

    /// Removes the observer (an owner going away calls it; the observer
    /// holds the meter weakly, so a forgotten one does nothing).
    public func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    private func observe(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity.contains(.afterWaiting) {
            awakeSince = now
        } else if let since = awakeSince {
            busy += now - since
            longest = max(longest, now - since)
            awakeSince = nil
        }
    }

    /// Milliseconds awake since the last call (the span still running
    /// included), and the longest single span.
    public func take() -> (busyMs: Double, longestMs: Double) {
        let now = CACurrentMediaTime()
        var total = busy
        var top = longest
        if let since = awakeSince {
            total += now - since
            top = max(top, now - since)
            awakeSince = now
        }
        busy = 0
        longest = 0
        return (total * 1000, top * 1000)
    }
}
#endif
