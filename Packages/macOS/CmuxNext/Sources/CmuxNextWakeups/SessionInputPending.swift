public import AppKit
import CoreGraphics

/// The production check: the window server's time of the last input event of each kind that counts
/// in this login session, against the timestamp of the last such event AppKit dispatched in this app.
///
/// An event that the HID system generated after the last one the app dispatched is still on its
/// way through the event queue. What counts (``Kinds``), and why it is this app's:
/// - a key-down or a mouse-button-down: what a person waits on; the app is active, so it is ours;
/// - a scroll that begins a sequence, while the pointer is over one of the app's windows (macOS
///   sends a scroll to the window under the pointer, not to the active app). A tick inside the
///   sequence the last dispatched scroll left open (``ScrollLatching``: a running gesture, its
///   momentum, a wheel notch's latching window) does not count. Chrome holds only the first wheel
///   of a sequence the same way (`components/input/mouse_wheel_event_queue.h`);
/// - a left drag while the left button that started it is down in this app.
///
/// Mouse moves and other drags stream at the pointer's rate and never count. A drag counts in
/// every check it is on its way; ``MainFrameBudget``'s own progress rule (a class that yielded in
/// one frame runs in the next) aligns its yields to the frame, as Chrome aligns drags to the
/// begin-frame (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.h`,
/// IsRafAlignedEvent).
///
/// Two bounds keep an event the app never dispatches from holding batches back:
/// - an event older than ``staleAfter`` does not count (taken by another process while the app
///   turns inactive);
/// - a scroll begin or a drag counts for ``staleAfter`` from the first check that saw it
///   undispatched, then not until one is dispatched: the stream goes to another window (a gesture
///   macOS latched there) or to a tracking loop (a window move, a dragging session).
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
/// let budget = MainFrameBudget(input: SessionInputPending(events: WindowServerInputEvents(input: inputTap)), signposts: true)
/// // A test, with its own window-server times and dispatch record:
/// let events = FakeSessionEvents()
/// let input = SessionInputPending(events: events)
/// ```
@MainActor
public final class SessionInputPending: InputPendingSource {
    /// The kinds of input pending at one check: the bitset the pending-input state publishes.
    public struct Kinds: OptionSet, Sendable, Hashable {
        /// The kinds' bits.
        public let rawValue: UInt8
        /// Kinds from their bits.
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// A key-down.
        public static let key = Kinds(rawValue: 1 << 0)
        /// A mouse-button-down.
        public static let click = Kinds(rawValue: 1 << 1)
        /// The first scroll of a new scroll sequence.
        public static let scrollBegin = Kinds(rawValue: 1 << 2)
        /// A drag of the left button.
        public static let drag = Kinds(rawValue: 1 << 3)
    }

    /// One input event AppKit dispatched in this app.
    public struct Dispatched: Sendable, Equatable {
        /// What the event was, as the pending-input check tells events apart.
        public enum Kind: Sendable, Equatable {
            /// A key-down, or a right or other mouse-button-down.
            case keyOrClick
            /// A left mouse-button-down: a click, and the start of the left drag after it.
            case leftMouseDown
            /// A left mouse-button-up: the end of the left drag.
            case leftMouseUp
            /// A left-button drag.
            case leftDrag
            /// A scroll, with its gesture phase and momentum phase (both empty for a wheel notch).
            case scroll(phase: NSEvent.Phase, momentum: NSEvent.Phase)
            /// Anything else (key-up, modifiers, moves, other drags).
            case other
        }

        /// Seconds since boot (the `NSEvent.timestamp` base).
        public var timestamp: TimeInterval
        /// What the event was.
        public var kind: Kind

        /// An event dispatched at `timestamp` (seconds since boot).
        public init(timestamp: TimeInterval, kind: Kind) {
            self.timestamp = timestamp
            self.kind = kind
        }
    }

    /// The shortest ``staleAfter``: two 60 Hz frames. A real key must not go stale while the main
    /// thread finishes a task the budget let run (a class's first task of a frame always runs, and
    /// a render pass may take ``MainFrameBudget/Budgets/passTarget``), also on a 120 Hz or faster
    /// display.
    public static let minimumStaleAfter: TimeInterval = 2.0 / 60

    private static let keyOrClickTypes: [(CGEventType, Kinds)] = [
        (.keyDown, .key), (.leftMouseDown, .click), (.rightMouseDown, .click), (.otherMouseDown, .click),
    ]
    private let events: any SessionInputEvents
    private let latching: ScrollLatching
    /// The newest key-down or mouse-button-down AppKit dispatched here.
    private var lastDispatchedKeyOrClick: TimeInterval = 0
    /// The newest scroll AppKit dispatched here.
    private var lastDispatchedScroll: TimeInterval = 0
    /// Until when (seconds since boot) the last dispatched scroll keeps its sequence open.
    private var scrollSequenceOpenUntil: TimeInterval = -.infinity
    /// The newest left-button-down or left drag AppKit dispatched here.
    private var lastDispatchedDrag: TimeInterval = 0
    /// The left button went down in this app and AppKit has not dispatched its mouse-up.
    private var leftButtonDown = false
    /// The newest input event of any type AppKit dispatched here.
    private var lastDispatchedAny: TimeInterval = 0
    /// When a check first saw an undispatched scroll begin (seconds since boot); nil while none is
    /// on its way. An observation of the event stream: the same whichever caller checks.
    private var undispatchedScrollSeen: TimeInterval?
    /// When a check first saw an undispatched left drag; nil while none is on its way.
    private var undispatchedDragSeen: TimeInterval?

    /// Told after each dispatched event that counts (a key, a mouse button, a scroll, a left drag;
    /// not moves or modifiers): the composition root ends the idle scheduler's wait for pending
    /// input there (``IdleScheduler/noteInput()``). Dispatches are observed from the first check.
    public var onInputDispatched: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - events: The window server and AppKit (tests: a fake that reports its own event times,
    ///     dispatches, pointer and refresh interval).
    ///   - latching: How long a dispatched scroll keeps its sequence open.
    public init(events: any SessionInputEvents, latching: ScrollLatching = ScrollLatching()) {
        self.events = events
        self.latching = latching
        events.observeDispatch { [weak self] event in self?.dispatched(event) }
    }

    /// How long an undispatched event counts as pending: two refresh intervals of the display the
    /// person works on, never less than ``minimumStaleAfter`` (33.3 ms at 60 Hz and faster, 41.7 ms
    /// at 48 Hz).
    public var staleAfter: TimeInterval { max(2 * refreshInterval, Self.minimumStaleAfter) }

    /// The display's refresh interval in seconds; 60 Hz when it reports none.
    public var refreshInterval: TimeInterval {
        let interval = events.refreshInterval
        return interval.isFinite && interval > 0 ? interval : 1.0 / 60
    }

    private func dispatched(_ event: Dispatched) {
        let time = event.timestamp
        lastDispatchedAny = max(lastDispatchedAny, time)
        switch event.kind {
        case .keyOrClick:
            lastDispatchedKeyOrClick = max(lastDispatchedKeyOrClick, time)
        case .leftMouseDown:
            lastDispatchedKeyOrClick = max(lastDispatchedKeyOrClick, time)
            lastDispatchedDrag = max(lastDispatchedDrag, time)
            leftButtonDown = true
            undispatchedDragSeen = nil
        case .leftMouseUp:
            leftButtonDown = false
            undispatchedDragSeen = nil
        case .leftDrag:
            lastDispatchedDrag = max(lastDispatchedDrag, time)
            undispatchedDragSeen = nil
        case let .scroll(phase, momentum):
            lastDispatchedScroll = max(lastDispatchedScroll, time)
            scrollSequenceOpenUntil = latching.sequenceOpen(after: time, phase: phase, momentum: momentum)
            undispatchedScrollSeen = nil
        case .other:
            return
        }
        onInputDispatched?()
    }

    /// Whether any input the app has not dispatched yet is waiting at `uptime` (seconds since boot).
    public func hasPendingInput(uptime: TimeInterval) -> Bool {
        !scan(uptime: uptime, firstOnly: true).isEmpty
    }

    /// Whether a mouse button, a scroll begin or a drag is pending: input that goes to the view under the pointer.
    public func hasPendingPointerInput(uptime: TimeInterval) -> Bool {
        !pendingKinds(uptime: uptime).subtracting(.key).isEmpty
    }

    /// Every kind of input pending at `uptime` (seconds since boot), for the input-turn hop
    /// recorder's turn. Empty when the app is inactive. Safe next to the budget's checks: the only state a check keeps is when it first
    /// saw an undispatched scroll begin or drag, which is the same whoever looks.
    public func pendingKinds(uptime: TimeInterval) -> Kinds {
        scan(uptime: uptime, firstOnly: false)
    }

    private func scan(uptime: TimeInterval, firstOnly: Bool) -> Kinds {
        guard events.isAppActive else {
            // A gesture or a drag the app lost to another app never sends its end here.
            scrollSequenceOpenUntil = -.infinity
            leftButtonDown = false
            undispatchedScrollSeen = nil
            undispatchedDragSeen = nil
            return []
        }
        let stale = staleAfter
        // One query: nothing generated after the last dispatched event, or nothing recent, means
        // nothing that counts is on its way either (the event queue is first in, first out).
        // Events a tracking loop takes (a drag, a menu) never reach the input tap, so during one
        // this answers "maybe" and the per-type queries decide.
        guard Self.isPending(age: events.secondsSinceLastInput(), after: lastDispatchedAny, now: uptime, staleAfter: stale) else {
            undispatchedScrollSeen = nil
            undispatchedDragSeen = nil
            return []
        }
        var kinds: Kinds = []
        for (type, kind) in Self.keyOrClickTypes where !kinds.contains(kind) {
            guard Self.isPending(age: events.secondsSinceLastEvent(type), after: lastDispatchedKeyOrClick, now: uptime, staleAfter: stale) else { continue }
            kinds.insert(kind)
            if firstOnly { return kinds }
        }
        if scrollBeginCounts(now: uptime, staleAfter: stale) {
            kinds.insert(.scrollBegin)
            if firstOnly { return kinds }
        }
        if dragCounts(now: uptime, staleAfter: stale) { kinds.insert(.drag) }
        return kinds
    }

    /// Whether a scroll that begins a sequence is on its way to one of the app's windows.
    private func scrollBeginCounts(now: TimeInterval, staleAfter: TimeInterval) -> Bool {
        let age = events.secondsSinceLastEvent(.scrollWheel)
        guard Self.isPending(age: age, after: lastDispatchedScroll, now: now, staleAfter: staleAfter) else {
            undispatchedScrollSeen = nil
            return false
        }
        // A tick of the sequence the last dispatched scroll left open streams with it.
        guard now - age >= scrollSequenceOpenUntil, events.pointerIsOverAppWindow else { return false }
        return Self.stillCounts(firstSeen: &undispatchedScrollSeen, now: now, staleAfter: staleAfter)
    }

    /// Whether a left drag of a button that went down in this app is on its way.
    private func dragCounts(now: TimeInterval, staleAfter: TimeInterval) -> Bool {
        guard leftButtonDown else { return false }
        let age = events.secondsSinceLastEvent(.leftMouseDragged)
        guard Self.isPending(age: age, after: lastDispatchedDrag, now: now, staleAfter: staleAfter) else {
            undispatchedDragSeen = nil
            return false
        }
        guard Self.stillCounts(firstSeen: &undispatchedDragSeen, now: now, staleAfter: staleAfter) else {
            // A tracking loop took the drag (a window move, a dragging session): its mouse-up never
            // comes here either, so the drag is over for this app.
            leftButtonDown = false
            return false
        }
        return true
    }

    /// Whether an undispatched stream still counts: for `staleAfter` from the first check that saw
    /// it (`firstSeen`, set here by that check).
    private static func stillCounts(firstSeen: inout TimeInterval?, now: TimeInterval, staleAfter: TimeInterval) -> Bool {
        let seen = firstSeen ?? now
        firstSeen = seen
        return now - seen < staleAfter
    }

    /// Whether an event generated `age` seconds before `now` (seconds since boot) is newer than
    /// `dispatched` and younger than `staleAfter`. 1 ms: the HID time and the event's timestamp
    /// come from one clock but are rounded apart.
    private static func isPending(age: TimeInterval, after dispatched: TimeInterval, now: TimeInterval, staleAfter: TimeInterval) -> Bool {
        now - age > dispatched + 0.001 && age < staleAfter
    }
}
