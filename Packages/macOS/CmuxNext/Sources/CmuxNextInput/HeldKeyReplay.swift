public import AppKit

/// The one place a key event that a cmux path held is sent again (the input rule: a held key is a measured stage).
///
/// A path that holds a person's key to run it later (``KeyArrivalLedger/HoldPath``) runs it through
/// ``replay(_:heldBy:keyWindow:_:)``. The seam records the hold as its own stage: per path, how many keys it held and
/// how long each waited (from the hold, ``KeyArrivalLedger/holdStart(of:)``, to its last replay), and it logs a late
/// key in the ledger (`debug.input late_keys`). A key that its own replay holds again (the launch picture: undecided,
/// then for a terminal still a picture) is one key: its later replay replaces its earlier record. Only the ``Sender``
/// it hands out sends the event (to the application, a window or a view): a held key goes on through it, never through
/// its own `sendEvent` call. The app has one seam per ledger (`InputLatencyDispatch.heldKeys`): two seams on one
/// ledger would take back each other's records.
///
/// The input rule: a person's key goes at once to its destination by id (terminal, pane or page id), which queues it;
/// a path may hold it only with a written reason, a limit of at most ``limitNanos`` and this stage. Its numbers are in
/// `debug.input late_keys` under `holds` (``stages``).
///
/// ```swift
/// heldKeys.replay(event, heldBy: .newTab, keyWindow: window) { send in
///     router.dispatchingSynthetic(event) {
///         guard !router.interceptKeyDown(event, in: window) else { return }
///         send.window(window, event)
///     }
/// }
/// ```
@MainActor
public final class HeldKeyReplay {
    /// The longest a path may hold a person's key (the input rule above).
    public nonisolated static let limitNanos: UInt64 = 50_000_000
    /// Upper bounds of the hold buckets in milliseconds; the last bucket has no upper bound.
    public nonisolated static let bucketBoundsMilliseconds: [UInt64] = [8, 16, 33, 50, 100, 250, 500, 1000, 2000]

    /// One path's holds since launch.
    public nonisolated struct Stage: Sendable, Equatable {
        /// Keys the path sent again.
        public var count: UInt64 = 0
        /// Of those, keys held longer than ``HeldKeyReplay/limitNanos``.
        public var overLimit: UInt64 = 0
        /// The longest hold.
        public var maxNanos: UInt64 = 0
        /// The sum of the holds (the mean is `totalNanos / count`).
        public var totalNanos: UInt64 = 0
        /// Keys per bucket of ``HeldKeyReplay/bucketBoundsMilliseconds`` (one more for the holds past the last bound).
        public var buckets: [UInt64] = Array(repeating: 0, count: HeldKeyReplay.bucketBoundsMilliseconds.count + 1)

        public init() {}

        mutating func add(_ nanos: UInt64) {
            count &+= 1
            totalNanos &+= nanos
            if nanos > HeldKeyReplay.limitNanos { overLimit &+= 1 }
            maxNanos = max(maxNanos, nanos)
            buckets[Self.bucket(of: nanos)] &+= 1
        }

        /// Takes back one key's earlier record of `nanos` (its later replay records the whole hold). The max stays: a
        /// later hold of the same key is never shorter.
        mutating func remove(_ nanos: UInt64) {
            count &-= 1
            totalNanos &-= nanos
            if nanos > HeldKeyReplay.limitNanos { overLimit &-= 1 }
            buckets[Self.bucket(of: nanos)] &-= 1
        }

        private static func bucket(of nanos: UInt64) -> Int {
            let milliseconds = nanos / 1_000_000
            return HeldKeyReplay.bucketBoundsMilliseconds.firstIndex { milliseconds < $0 } ?? HeldKeyReplay.bucketBoundsMilliseconds.count
        }
    }

    /// The app's latency dispatch: each replay opens the key's slot around its whole run (the router included), as
    /// `NSApplication.sendEvent` does, unless it goes through `sendEvent` itself (`throughApplication`). Nil opens none
    /// (a router a test made).
    public weak var dispatch: InputLatencyDispatch?

    /// Sends a held event on; only ``replay(_:heldBy:keyWindow:throughApplication:_:)`` makes one, after it recorded the
    /// hold.
    public struct Sender {
        fileprivate init() {}

        /// Through the application's dispatch (`NSApplication.sendEvent`): the key opens its own latency slot and passes
        /// the key router again, as a key from the event queue does. Only with `throughApplication: true`.
        public func application(_ event: NSEvent) { NSApp.sendEvent(event) }

        /// Straight to `window` (`NSWindow.sendEvent`): the caller already ran the key router.
        public func window(_ window: NSWindow, _ event: NSEvent) { window.sendEvent(event) }

        /// Straight to `view`'s `keyDown(with:)` (a key-down only): the view is the key's known destination.
        public func view(_ view: NSResponder, _ event: NSEvent) { view.keyDown(with: event) }
    }

    private let ledger: KeyArrivalLedger?
    private let now: () -> UInt64
    private var paths: [Stage]

    /// - Parameters:
    ///   - ledger: The app's key ledger (`InputLatencyDispatch.arrivals`): when each key was held, and the late-key
    ///     log. Nil: a hold counts from the key's OS time.
    ///   - now: `CLOCK_UPTIME_RAW` nanoseconds (tests pass their own).
    public init(ledger: KeyArrivalLedger?, now: @escaping () -> UInt64 = InputLatencyTracker.uptimeNanos) {
        self.ledger = ledger
        self.now = now
        paths = KeyArrivalLedger.HoldPath.allCases.map { _ in Stage() }
    }

    /// Runs `event`, which `path` held, again now: records the hold in `path`'s stage, opens the key's latency slot
    /// (its first arrival is its `arrivedMain`, its frame closes it) and logs it when it is late, then hands `send` the
    /// one ``Sender``. A key the router decides again (an action runs) counts too.
    ///
    /// - Parameters:
    ///   - event: The key event as the person typed it (the one the hold took).
    ///   - path: The path that held it.
    ///   - keyWindow: The window it goes to (its slot's target and the late-key log's responder chain).
    ///   - throughApplication: `send` uses ``Sender/application(_:)``, whose `sendEvent` opens the slot itself.
    ///   - send: Sends `event`, or an event made from it, through the ``Sender``.
    public func replay(_ event: NSEvent, heldBy path: KeyArrivalLedger.HoldPath, keyWindow: NSWindow?,
                       throughApplication: Bool = false, _ send: (Sender) -> Void) {
        let at = now()
        if path != .none {
            let start = ledger?.holdStart(of: event) ?? InputLatencyTracker.eventNanos(event.timestamp)
            let hold = start > 0 && at > start ? at - start : 0
            // A key replayed before (its own replay held it again) keeps one record: the earlier one goes.
            if let earlier = ledger?.recordReplay(event, path: path, hold: hold), earlier.path != .none {
                paths[Int(earlier.path.rawValue)].remove(earlier.hold)
            }
            paths[Int(path.rawValue)].add(hold)
        }
        // The key's slot spans the whole run, as `sendEvent`'s does, and logs it when late; without one the seam logs it.
        let slot = throughApplication ? nil : dispatch?.willDispatch(event, synthetic: ledger?.isSynthetic(event) ?? false,
                                                                     keyWindow: keyWindow)
        if dispatch == nil, !throughApplication, event.type == .keyDown { ledger?.replayed(event, at: at, keyWindow: keyWindow) }
        send(Sender())
        if let slot { dispatch?.didDispatch(slot, layoutTookScroll: false) }
    }

    /// `path`'s holds since launch.
    public func stage(_ path: KeyArrivalLedger.HoldPath) -> Stage { paths[Int(path.rawValue)] }

    /// Every path that held a key since launch, in ``KeyArrivalLedger/HoldPath`` order.
    public var stages: [(path: KeyArrivalLedger.HoldPath, stage: Stage)] {
        KeyArrivalLedger.HoldPath.allCases.compactMap { path in
            let stage = paths[Int(path.rawValue)]
            return stage.count > 0 ? (path, stage) : nil
        }
    }
}
