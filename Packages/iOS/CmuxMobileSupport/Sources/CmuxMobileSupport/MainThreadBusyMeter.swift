#if DEBUG && canImport(UIKit)
public import QuartzCore
import Foundation

/// DEBUG only. How long the main thread was awake (running anything: app
/// code, UIKit layout, Core Animation's commit) since the last `take()`,
/// from the main run loop's after-waiting and before-waiting activities.
/// The DEBUG frame traces read it once per display frame, to tell a long
/// frame the app's main thread caused from one it did not (the render
/// server, the simulator's keyboard). `commit` is the part spent from just
/// before Core Animation's commit observer (order 2_000_000: layout, SwiftUI
/// hosting updates, display) to the end of the run loop pass; the rest is
/// events, timers and notification handlers.
@MainActor
public final class MainThreadBusyMeter {
    private var observer: CFRunLoopObserver?
    private var commitObserver: CFRunLoopObserver?
    private var commitSince: CFTimeInterval?
    private var commit: CFTimeInterval = 0
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
        let commitObserver = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_999
        ) { [weak self] _, _ in
            // main-proof: added to the main run loop only, as above.
            MainActor.assumeIsolated { self?.commitSince = CACurrentMediaTime() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), commitObserver, .commonModes)
        self.commitObserver = commitObserver
        awakeSince = CACurrentMediaTime()
    }

    /// Removes the observer (an owner going away calls it; the observer
    /// holds the meter weakly, so a forgotten one does nothing).
    public func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        if let commitObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), commitObserver, .commonModes) }
        observer = nil
        commitObserver = nil
    }

    private func observe(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity.contains(.afterWaiting) {
            awakeSince = now
        } else if let since = awakeSince {
            if let start = commitSince { commit += now - start }
            commitSince = nil
            busy += now - since
            longest = max(longest, now - since)
            awakeSince = nil
        }
    }

    /// Milliseconds awake since the last call (the span still running
    /// included), and the longest single span.
    public func take() -> (busyMs: Double, longestMs: Double, commitMs: Double) {
        let now = CACurrentMediaTime()
        var total = busy
        var top = longest
        if let since = awakeSince {
            total += now - since
            top = max(top, now - since)
            awakeSince = now
        }
        let committed = commit
        busy = 0
        longest = 0
        commit = 0
        return (total * 1000, top * 1000, committed * 1000)
    }
}
#endif
