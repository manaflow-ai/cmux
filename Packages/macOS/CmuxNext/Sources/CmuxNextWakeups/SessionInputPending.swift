public import Foundation
import CoreGraphics

/// The production check: the window server's time of the last input event of each kind that counts
/// in this login session, against the timestamp of the last such event AppKit dispatched in this app.
///
/// An event that the HID system generated after the last one the app dispatched is still on its
/// way through the event queue: the app is active, so it is ours. What counts (``Kinds``):
/// - a key-down or a mouse-button-down: what a person waits on;
/// - a scroll that begins a gesture (phase began after the last gesture ended, or a wheel notch
///   with no phase); ticks in the middle of a gesture do not count. Chrome holds only the first
///   wheel of a sequence the same way (`components/input/mouse_wheel_event_queue.h`);
/// - an active left drag, at most one refresh interval in two: after a drag counted for one
///   interval, drags do not count for the next, so a batch that yielded to a drag in one frame
///   runs in the next. Chrome aligns drags to the frame (`third_party/blink/renderer/platform/
///   widget/input/main_thread_event_queue.h`, IsRafAlignedEvent).
///
/// Mouse moves and other drags stream at the pointer's rate and never count. An event the app never
/// dispatches (taken by another process while the app turns inactive) stops counting after
/// ``staleAfter``, two refresh intervals of the main screen, so it cannot hold batches back.
///
/// Each check is one window-server query in the common case: the newest input event of any type
/// (``SessionInputEvents/secondsSinceLastInput()``). When that event is no newer than the last one
/// AppKit dispatched here, or is stale, nothing that counts can be pending (each is an input
/// event, and the app's event queue is first in, first out), so the check ends there. Only when
/// some input is still on its way does it ask per type (key-down, each mouse button, then the
/// scroll and the left drag).
///
/// ```swift
/// // The app:
/// let budget = MainFrameBudget(input: SessionInputPending(), signposts: true)
/// // A test, with its own window-server times and dispatch record:
/// let events = FakeSessionEvents()
/// let input = SessionInputPending(events: events)
/// ```
@MainActor
public final class SessionInputPending: InputPendingSource {
    /// The kinds of input pending at one check: the bitset the pending-input state publishes.
    public struct Kinds: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let key = Kinds(rawValue: 1 << 0)
        public static let click = Kinds(rawValue: 1 << 1)
        public static let scrollBegin = Kinds(rawValue: 1 << 2)
        public static let drag = Kinds(rawValue: 1 << 3)
    }

    /// One input event AppKit dispatched in this app.
    public struct Dispatched: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A key-down or a mouse-button-down.
            case keyOrClick
            /// A left-button drag.
            case leftDrag
            /// A scroll; `gestureContinues` when its phase leaves a gesture running (the next tick
            /// is part of it).
            case scroll(gestureContinues: Bool)
            /// Anything else (key-up, modifiers, moves, other drags).
            case other
        }

        /// Seconds since boot (the `NSEvent.timestamp` base).
        public var timestamp: TimeInterval
        public var kind: Kind

        public init(timestamp: TimeInterval, kind: Kind) {
            self.timestamp = timestamp
            self.kind = kind
        }
    }

    private static let keyOrClickTypes: [(CGEventType, Kinds)] = [
        (.keyDown, .key), (.leftMouseDown, .click), (.rightMouseDown, .click), (.otherMouseDown, .click),
    ]
    private let events: any SessionInputEvents
    /// The newest key-down or mouse-button-down AppKit dispatched here.
    private var lastDispatchedKeyOrClick: TimeInterval = 0
    /// The newest scroll AppKit dispatched here.
    private var lastDispatchedScroll: TimeInterval = 0
    /// The newest left drag AppKit dispatched here.
    private var lastDispatchedDrag: TimeInterval = 0
    /// The newest input event of any type AppKit dispatched here.
    private var lastDispatchedAny: TimeInterval = 0
    /// The last dispatched scroll left a gesture running: a pending scroll is a mid-gesture tick.
    private var scrollGestureRunning = false
    /// When a drag last started counting (seconds since boot); nil before the first.
    private var dragCountedSince: TimeInterval?
    private var observing = false

    /// - Parameter events: The window server and AppKit (tests: a fake that reports its own event
    ///   times, dispatches and refresh interval).
    public init(events: any SessionInputEvents = WindowServerInputEvents()) {
        self.events = events
    }

    /// How long an undispatched event counts as pending: two refresh intervals of the main screen
    /// (33.3 ms at 60 Hz, 16.7 ms at 120 Hz), longer than any dispatch delay the budget allows, so
    /// a real pending event is never missed while a lost one defers at most two frames of batches.
    public var staleAfter: TimeInterval { 2 * refreshInterval }

    /// The main screen's refresh interval; 60 Hz when the screen reports none.
    private var refreshInterval: TimeInterval {
        let interval = events.refreshInterval
        return interval.isFinite && interval > 0 ? interval : 1.0 / 60
    }

    private func dispatched(_ event: Dispatched) {
        lastDispatchedAny = max(lastDispatchedAny, event.timestamp)
        switch event.kind {
        case .keyOrClick: lastDispatchedKeyOrClick = max(lastDispatchedKeyOrClick, event.timestamp)
        case .leftDrag: lastDispatchedDrag = max(lastDispatchedDrag, event.timestamp)
        case let .scroll(gestureContinues):
            lastDispatchedScroll = max(lastDispatchedScroll, event.timestamp)
            scrollGestureRunning = gestureContinues
        case .other: break
        }
    }

    public func hasPendingInput(uptime: TimeInterval) -> Bool {
        !scan(uptime: uptime, firstOnly: true).isEmpty
    }

    /// Every kind of input pending at `uptime` (seconds since boot): what the run-loop turn's
    /// observer publishes into the pending-input state. Empty when the app is inactive.
    public func pendingKinds(uptime: TimeInterval) -> Kinds {
        scan(uptime: uptime, firstOnly: false)
    }

    private func scan(uptime: TimeInterval, firstOnly: Bool) -> Kinds {
        if !observing {
            observing = events.observeDispatch { [weak self] event in self?.dispatched(event) }
        }
        guard events.isAppActive else {
            // A gesture the app lost to another app never sends its end here.
            scrollGestureRunning = false
            return []
        }
        let interval = refreshInterval
        let stale = 2 * interval
        // One query: nothing generated after the last dispatched event, or nothing recent, means
        // nothing that counts is on its way either (the event queue is first in, first out).
        // Events a tracking loop takes (a drag, a menu) never reach the monitor, so during one
        // this answers "maybe" and the per-type queries decide.
        guard Self.isPending(age: events.secondsSinceLastInput(), after: lastDispatchedAny, now: uptime, staleAfter: stale) else { return [] }
        var kinds: Kinds = []
        for (type, kind) in Self.keyOrClickTypes where !kinds.contains(kind) {
            guard Self.isPending(age: events.secondsSinceLastEvent(type), after: lastDispatchedKeyOrClick, now: uptime, staleAfter: stale) else { continue }
            kinds.insert(kind)
            if firstOnly { return kinds }
        }
        if !scrollGestureRunning,
           Self.isPending(age: events.secondsSinceLastEvent(.scrollWheel), after: lastDispatchedScroll, now: uptime, staleAfter: stale) {
            kinds.insert(.scrollBegin)
            if firstOnly { return kinds }
        }
        if dragMayCount(now: uptime, interval: interval),
           Self.isPending(age: events.secondsSinceLastEvent(.leftMouseDragged), after: lastDispatchedDrag, now: uptime, staleAfter: stale) {
            // A new counting interval starts; inside the current one the start stays.
            if dragCountedSince.map({ uptime - $0 >= 2 * interval }) ?? true { dragCountedSince = uptime }
            kinds.insert(.drag)
        }
        return kinds
    }

    /// A drag counts for one refresh interval from when it started counting, then not for the next
    /// interval, then may start again.
    private func dragMayCount(now: TimeInterval, interval: TimeInterval) -> Bool {
        guard let since = dragCountedSince else { return true }
        let elapsed = now - since
        return elapsed < interval || elapsed >= 2 * interval
    }

    /// Whether an event generated `age` seconds before `now` (seconds since boot) is newer than
    /// `dispatched` and younger than `staleAfter`. 1 ms: the HID time and the event's timestamp
    /// come from one clock but are rounded apart.
    private static func isPending(age: TimeInterval, after dispatched: TimeInterval, now: TimeInterval, staleAfter: TimeInterval) -> Bool {
        now - age > dispatched + 0.001 && age < staleAfter
    }
}
