public import AppKit

/// A continuous input kind that ``FrameInputCoalescer`` merges per frame (Chromium's
/// continuous events: mouse move, touch move, wheel; `main_thread_event_queue.cc`
/// `IsContinuousEvent`). Discrete input (keys, button presses and releases) is never coalesced.
public enum FrameInputKind: Hashable, Sendable {
    /// The pointer moved with no button down (`mouseMoved`).
    case pointerMove
    /// The pointer moved with a button down (any `*MouseDragged`).
    case drag
    /// A scroll wheel or trackpad scroll.
    case scroll
    /// A trackpad pinch (`magnify`).
    case magnify

    /// The kind of a continuous event type; nil for discrete or non-input types.
    public init?(_ type: NSEvent.EventType) {
        switch type {
        case .mouseMoved: self = .pointerMove
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: self = .drag
        case .scrollWheel: self = .scroll
        case .magnify: self = .magnify
        default: return nil
        }
    }
}

/// One continuous input event as a value, so a frame's events can be kept and handed over
/// together (Chromium's `WebCoalescedInputEvent` keeps the originals for getCoalescedEvents).
public struct FrameInputSample: Sendable, Equatable {
    /// Where the event happened, in its window's coordinates.
    public var location: CGPoint
    /// How far it moved: the pointer delta for moves and drags, the scrolling delta for scrolls,
    /// the magnification in `dx` for a pinch. ``FrameInputCoalescer`` adds them up.
    public var delta: CGVector
    /// The event's timestamp (seconds since boot, as `NSEvent.timestamp`).
    public var timestamp: TimeInterval
    /// The modifier keys held during the event.
    public var modifierFlags: NSEvent.ModifierFlags

    /// A sample of one event's values (``FrameInputCoalescer`` makes them from `NSEvent`s; tests build them).
    public init(location: CGPoint, delta: CGVector, timestamp: TimeInterval, modifierFlags: NSEvent.ModifierFlags = []) {
        self.location = location
        self.delta = delta
        self.timestamp = timestamp
        self.modifierFlags = modifierFlags
    }

    /// The sample of `event`; the delta is zero for a type with none.
    @MainActor public init(_ event: NSEvent) {
        let delta: CGVector = switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: CGVector(dx: event.deltaX, dy: event.deltaY)
        case .scrollWheel: CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        case .magnify: CGVector(dx: event.magnification, dy: 0)
        default: .zero
        }
        self.init(location: event.locationInWindow, delta: delta, timestamp: event.timestamp, modifierFlags: event.modifierFlags)
    }
}
