import CmuxNextCompat
public import QuartzCore

/// The main run loop's awake time per display frame, for a frame probe (`debug.frames`): two observers of the main
/// run loop while installed, one when it wakes (first of the pass, `CFIndex.min`), one before it waits (last,
/// `CFIndex.max`, after AppKit's layout and display and the Core Animation commit), so the time between them is the
/// main thread's work. Chrome's `ThreadControllerWithMessagePumpImpl` brackets each pump the same way to report
/// the main thread's busy time (base/task/sequence_manager/thread_controller_with_message_pump_impl.cc).
///
/// ```swift
/// let awake = MainRunLoopAwakeTime()
/// awake.install()
/// // Each frame:
/// let busy = awake.take()
/// ```
@MainActor
public final class MainRunLoopAwakeTime {
    private var observers: [CFRunLoopObserver] = []
    /// When the main run loop last woke (0 while it waits), and its awake time since the last ``take()``.
    private var awakeSince: CFTimeInterval = 0
    private var awake: CFTimeInterval = 0

    public init() {}

    /// Adds the two observers (a second call does nothing).
    public func install() {
        guard observers.isEmpty else { return }
        let woke = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.didWake() } // main-proof: an observer of the main run loop
        }
        // It only reads the clock: its context says so to the commit-boundary audit.
        let sleeps: CFRunLoopObserver? = MainRunLoopObserver.afterCommitObserver(activities: .beforeWaiting, order: CFIndex.max) { [weak self] _ in
            MainActor.assumeIsolated { self?.willWait() } // main-proof: an observer of the main run loop
        }
        guard let woke, let sleeps else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), woke, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleeps, .commonModes)
        observers = [woke, sleeps]
    }

    /// Removes the observers.
    public func remove() {
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
        observers.removeAll()
    }

    /// Starts counting from now, as if the run loop just woke.
    public func reset() {
        awake = 0
        awakeSince = CACurrentMediaTime()
    }

    /// The awake time since the last take, the pass running now counted up to now; the count starts again.
    public func take() -> CFTimeInterval {
        if awakeSince > 0 {
            let now = CACurrentMediaTime()
            awake += now - awakeSince
            awakeSince = now
        }
        defer { awake = 0 }
        return awake
    }

    private func didWake() {
        awakeSince = CACurrentMediaTime()
    }

    private func willWait() {
        guard awakeSince > 0 else { return }
        awake += CACurrentMediaTime() - awakeSince
        awakeSince = 0
    }
}
