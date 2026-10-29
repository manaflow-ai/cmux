public import QuartzCore

/// The display links the frame schedulers other than the budgeted one tick on (``FrameScheduler/app``
/// and the window schedulers: window animations, `Motion.clock`, drag ghosts). The
/// ``MainWorkScheduler``'s idle class starts no long idle period while one runs and hears when the
/// last one goes; each of their frames may be followed by a short idle period, as Chrome runs a
/// short idle period after every `BeginMainFrame` whatever drives it
/// (`third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`,
/// `WillBeginFrame` and `DidCommitFrameToCompositor`).
@MainActor
public protocol OtherFrameLinks: AnyObject {
    /// Whether any of those display links exists.
    var anyRunning: Bool { get }
    /// Tells `subscription` of each flip of ``anyRunning`` and of each link frame, until it is
    /// released.
    func add(_ subscription: FrameLinksSubscription)
}

/// A subscription to ``OtherFrameLinks``: held weakly by the source, released with its owner.
@MainActor
public final class FrameLinksSubscription {
    /// Called with the new ``OtherFrameLinks/anyRunning``.
    public let changed: @MainActor (_ running: Bool) -> Void
    /// Called after each link frame with its timestamp and refresh period (`CACurrentMediaTime` seconds).
    public let frame: @MainActor (_ timestamp: CFTimeInterval, _ refreshInterval: Double) -> Void

    /// A subscription that calls `changed` when the first link starts or the last stops, and `frame` after each link frame.
    public init(changed: @escaping @MainActor (_ running: Bool) -> Void,
                frame: @escaping @MainActor (_ timestamp: CFTimeInterval, _ refreshInterval: Double) -> Void) {
        self.changed = changed
        self.frame = frame
    }
}

/// The app's ``OtherFrameLinks`` (its display clock's ``DisplayClock/unbudgetedLinks``): the
/// schedulers without a budget report when they start or stop ticking on a link, and each link
/// frame. A count, not a walk of ``FrameScheduler/all``.
@MainActor
public final class UnbudgetedFrameLinks: OtherFrameLinks {
    private var links = 0
    private var subscriptions: [WeakSubscription] = []

    /// A set with no link running.
    public init() {}

    /// Whether any other link is running.
    public var anyRunning: Bool { links > 0 }

    /// Adds `subscription`, held weakly; released subscriptions are dropped here.
    public func add(_ subscription: FrameLinksSubscription) {
        subscriptions.removeAll { $0.value == nil }
        subscriptions.append(WeakSubscription(value: subscription))
    }

    /// A scheduler started (`exists`) or stopped ticking on its display's link.
    func linkChanged(exists: Bool) {
        let was = links > 0
        links = exists ? links + 1 : max(0, links - 1)
        guard (links > 0) != was else { return }
        let running = links > 0
        for entry in subscriptions {
            entry.value?.changed(running)
        }
    }

    /// One frame of a scheduler's link.
    func frame(timestamp: CFTimeInterval, refreshInterval: Double) { // perf-hot: 0.5ms frame-tick (every frame)
        for entry in subscriptions {
            entry.value?.frame(timestamp, refreshInterval)
        }
    }

    private struct WeakSubscription {
        weak var value: FrameLinksSubscription?
    }
}
