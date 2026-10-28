public import CmuxNextInputCore
public import Foundation

/// Which events of `sendEvent` open an input latency slot, and as what kind. Pure: the event's type,
/// scroll phase and time in, a decision out.
///
/// Chrome makes one `EventMetrics` per dispatched input that a person waits on (cc/metrics/event_metrics.h): key
/// presses, mouse presses and releases, each scroll update (the first update after a scroll begins is its own type,
/// `kFirstGestureScrollUpdate`), and continuous moves coalesced to one per frame. Here:
/// - key down: a key press, at the keyboard focus. Key ups and modifier changes open none.
/// - mouse down and up: a press at the view under the pointer, a release where its press went (AppKit sends the up
///   to the view that took the down).
/// - drag: the first drag of each frame interval, counted from the press; later drags in the same interval are
///   coalesced into it (``InputLatencyDispatch`` counts them on its slot).
/// - scroll: began, each changed (the first after began is ``CmuxNextInputCore/InputEventKind/scrollFirstUpdate``) and
///   each moving momentum event (Chrome's `kInertialGestureScrollUpdate`), all at the view the gesture began over; a
///   mouse-wheel notch is an update at the view under it. A touch (`mayBegin`), end, cancel or momentum end opens
///   none.
/// - plain pointer moves and other gestures: none.
public nonisolated struct InputLatencySampling: Equatable, Sendable {
    /// Where the slot's target comes from.
    public nonisolated enum TargetSource: Equatable, Sendable {
        /// The keyboard focus of the key window.
        case keyboardFocus
        /// The view under the pointer now; later events of the press or gesture keep it.
        case underPointer
        /// The view the current press or scroll gesture began over.
        case latched
    }

    /// What to do with one event.
    public nonisolated enum Decision: Equatable, Sendable {
        /// Not tracked.
        case skip
        /// A slot of `kind` opens, its target from `target`.
        case open(InputEventKind, target: TargetSource)
        /// A drag in a frame interval that already has its drag slot: it joins that slot as a coalesced event.
        case coalesceDrag
    }

    /// The last scroll began, and no update came since.
    private var awaitingFirstScrollUpdate = false
    /// The frame interval index (since the press) of the last drag that opened a slot; nil since the last press.
    private var lastDragFrame: UInt64?
    /// The last press's time: frame intervals count from it.
    private var pressTimestamp: TimeInterval = 0

    public init() {}

    /// The decision for one event, and the state it leaves for the next.
    ///
    /// - Parameters:
    ///   - type: The event's type.
    ///   - scrollPhase: Where a scroll event is in its gesture; ``CmuxNextInputCore/InputScrollPhase/none`` otherwise.
    ///   - timestamp: The event's time, seconds since boot (`NSEvent.timestamp`).
    ///   - frameInterval: The display's refresh interval in seconds; read for drags only.
    // perf-hot: 0.05us key-dispatch
    public mutating func decide(_ type: InputEventType, scrollPhase: InputScrollPhase, timestamp: TimeInterval,
                                frameInterval: TimeInterval) -> Decision {
        switch type {
        case .keyDown:
            return .open(.keyPress, target: .keyboardFocus)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            lastDragFrame = nil
            pressTimestamp = timestamp
            return .open(.mousePress, target: .underPointer)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return .open(.mouseRelease, target: .latched)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let frame = UInt64(max(0, timestamp - pressTimestamp) / max(frameInterval, 0.001))
            guard frame != lastDragFrame else { return .coalesceDrag }
            lastDragFrame = frame
            return .open(.drag, target: .latched)
        case .scrollWheel:
            return decideScroll(scrollPhase)
        case .keyUp, .flagsChanged, .mouseMoved, .magnify, .rotate, .swipe, .smartMagnify, .pressure,
             .mouseEntered, .mouseExited:
            return .skip
        }
    }

    private mutating func decideScroll(_ phase: InputScrollPhase) -> Decision {
        switch phase {
        case .began:
            awaitingFirstScrollUpdate = true
            return .open(.scrollBegin, target: .underPointer)
        case .changed:
            let first = awaitingFirstScrollUpdate
            awaitingFirstScrollUpdate = false
            return .open(first ? .scrollFirstUpdate : .scrollUpdate, target: .latched)
        case .momentum:
            return .open(.scrollMomentum, target: .latched)
        case .none:
            return .open(.scrollUpdate, target: .underPointer)
        case .mayBegin, .ended, .cancelled, .momentumEnded:
            awaitingFirstScrollUpdate = false
            return .skip
        }
    }
}
