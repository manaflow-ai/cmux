#if DEBUG
import AppKit
import CmuxNextWakeups
import QuartzCore

/// Samples the app main thread's busy time per display frame while `debug.agent_pane fling`
/// (`wait`) scrolls the transcript, in either engine (``MainThreadFrameStats``). Two main run loop
/// observers in every common mode time the spans the loop is awake: one at wake, ordered first,
/// and one before it sleeps, ordered after AppKit's display and the Core Animation commit, so their
/// work counts. A client of the window's display link (``FrameClient``) closes a frame on each
/// tick. O(1) per wake and per frame; nothing per row.
///
/// Runs only while a fling is measured. Stop condition: ``stop()`` once the fling's reply is in
/// (the caller defers it), the `timeout` deadline, or `capacity` frames, whichever comes first.
/// Cleanup in ``stop()`` (idempotent): both observers are removed from the main run loop and
/// invalidated, the frame client is deactivated (the window's link pauses with its last client),
/// the deadline is cancelled. An observer that outlives its sampler invalidates itself.
@MainActor
final class MainThreadFrameSampler {
    private(set) var frames: [MainThreadFrameStats.Frame] = []
    private let capacity: Int
    private let deadline = DemandTimer(owner: MainThreadFrameSampler.owner)
    private var observers: [CFRunLoopObserver] = []
    private var client: FrameClient?
    /// When the loop last woke, nil while it sleeps.
    private var awakeSince: CFTimeInterval?
    /// Busy time since the last tick, of wake spans that ended.
    private var busy: CFTimeInterval = 0
    private var ticked = false

    nonisolated static let owner = "debug.agentPane.mainThreadFrames"

    /// Starts sampling on `view`'s window's display link.
    convenience init(view: NSView, timeout: Duration, capacity: Int = 8192) {
        self.init(scheduler: { [weak view] in view.map(FrameScheduler.forView) ?? .app }, timeout: timeout, capacity: capacity)
    }

    /// Starts sampling on the frames of the scheduler `scheduler` returns (a test's fake link).
    init(scheduler: @escaping @MainActor () -> FrameScheduler, timeout: Duration, capacity: Int = 8192) {
        self.capacity = capacity
        // Made from a main-actor handler: the loop is awake now.
        awakeSince = CACurrentMediaTime()
        observers = [observe(.afterWaiting, order: CFIndex.min), observe(.beforeWaiting, order: CFIndex.max)]
        let client = FrameClient(owner: Self.owner, isAnimation: false, scheduler: scheduler) { [weak self] tick in
            self?.frame(tick) ?? false
        }
        self.client = client
        client.activate()
        deadline.schedule(after: timeout) { @MainActor [weak self] in self?.stop() }
    }

    /// Whether it still samples (its observers are installed).
    var isSampling: Bool { !observers.isEmpty }

    /// Ends sampling; ``frames`` keeps what it took.
    func stop() {
        deadline.cancel()
        client?.deactivate()
        client = nil
        endObserving()
    }

    private func endObserving() {
        for observer in observers {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
        }
        observers = []
    }

    private func observe(_ activity: CFRunLoopActivity, order: CFIndex) -> CFRunLoopObserver {
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activity.rawValue, true, order) { [weak self] observer, activity in
            guard let self else {
                // Released without stop(): the observer ends itself.
                if let observer { CFRunLoopObserverInvalidate(observer) }
                return
            }
            MainActor.assumeIsolated { self.runLoop(activity) } // main-proof: the observer is added only to CFRunLoopGetMain() (below)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        return observer
    }

    private func runLoop(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
            if awakeSince == nil { awakeSince = now }
        } else if let since = awakeSince {
            busy += now - since
            awakeSince = nil
        }
    }

    /// Closes the frame that ends at this tick; false once sampling is over.
    private func frame(_ tick: FrameTick) -> Bool {
        guard !observers.isEmpty else { return false }
        let now = CACurrentMediaTime()
        var spent = busy
        if let since = awakeSince {
            // The loop is awake for this tick: the span so far is this frame's, the rest the next one's.
            spent += now - since
            awakeSince = now
        }
        busy = 0
        // The first tick only opens the first frame.
        if ticked { frames.append(.init(time: tick.timestamp, busy: spent, refresh: tick.refreshInterval)) }
        ticked = true
        guard frames.count < capacity else {
            // The scheduler drops a client whose tick returns false.
            deadline.cancel()
            endObserving()
            return false
        }
        return true
    }
}
#endif
