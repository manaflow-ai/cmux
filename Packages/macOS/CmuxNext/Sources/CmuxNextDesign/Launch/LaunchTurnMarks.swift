public import Foundation

/// REOPEN-F7 diagnosis (scratch build only, never merged): launch marks for the main run loop's first
/// iterations after `applicationDidFinishLaunching`, to split the time to the first window frame.
///
/// - `loop.N`: iteration N starts (before its timers; main-queue work and sources follow);
/// - `idle.K`: the run loop is about to sleep for the K-th time, before AppKit's display and the Core Animation
///   commit (both run in that same before-waiting pass);
/// - `idle.K.done`: that pass ended (display, commit and the other before-waiting observers ran);
/// - `wake.K`: the run loop woke from that sleep.
@MainActor
public final class LaunchTurnMarks {
    private var observers: [CFRunLoopObserver] = []
    private var iteration = 0
    private var sleeps = 0
    private let limit: Int
    private let mark: @MainActor (String) -> Void

    /// - Parameters:
    ///   - limit: The last iteration marked.
    ///   - mark: Records one launch mark.
    public init(limit: Int = 80, mark: @escaping @MainActor (String) -> Void) {
        self.limit = limit
        self.mark = mark
    }

    /// Adds the observers to the main run loop.
    public func start() {
        let activities = CFRunLoopActivity.beforeTimers.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.afterWaiting.rawValue
        let early = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, CFIndex.min) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.early(activity) } // main-proof: added only to CFRunLoopGetMain() (below)
        }
        let late = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.late() } // main-proof: added only to CFRunLoopGetMain() (below)
        }
        for observer in [early, late].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    private func early(_ activity: CFRunLoopActivity) {
        if activity.contains(.beforeTimers) {
            iteration += 1
            guard iteration <= limit else { return stop() }
            mark("loop.\(iteration)")
        } else if activity.contains(.beforeWaiting) {
            sleeps += 1
            mark("idle.\(sleeps)")
        } else if activity.contains(.afterWaiting) {
            mark("wake.\(sleeps)")
        }
    }

    private func late() {
        mark("idle.\(sleeps).done")
    }

    /// Removes the observers.
    public func stop() {
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
        observers.removeAll()
    }
}
