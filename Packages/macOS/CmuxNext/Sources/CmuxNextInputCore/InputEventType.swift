/// The input events the tap sees, without AppKit: one case per `NSEvent.EventType` that a person's
/// input produces.
public enum InputEventType: UInt8, Hashable, Sendable {
    case keyDown, keyUp, flagsChanged
    case leftMouseDown, leftMouseUp, rightMouseDown, rightMouseUp, otherMouseDown, otherMouseUp
    case mouseMoved
    case leftMouseDragged, rightMouseDragged, otherMouseDragged
    case scrollWheel
    case magnify, rotate, swipe, smartMagnify, pressure
    /// The pointer crossed a tracking area's edge (class ``InputEventClass/tracking``).
    case mouseEntered, mouseExited

    /// The class whose subscribers get this event.
    public var eventClass: InputEventClass {
        switch self {
        case .keyDown, .keyUp: .key
        case .flagsChanged: .flags
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: .button
        case .mouseMoved: .pointerMove
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: .drag
        case .scrollWheel: .scroll
        case .magnify, .rotate, .swipe, .smartMagnify, .pressure: .gesture
        case .mouseEntered, .mouseExited: .tracking
        }
    }

    /// A mouse button went down (any button).
    public var isButtonDown: Bool {
        self == .leftMouseDown || self == .rightMouseDown || self == .otherMouseDown
    }

    /// What a person waits on: a key down or a mouse button down.
    public var isKeyOrClick: Bool { self == .keyDown || isButtonDown }
}

/// Where a scroll event is in its gesture: momentum first (a coast carries no gesture phase), then
/// the gesture phase; a mouse wheel notch has neither.
public enum InputScrollPhase: UInt8, Hashable, Sendable {
    /// Not a scroll event, or a wheel notch with no phase.
    case none
    case mayBegin, began, changed, ended, cancelled
    /// Momentum (the coast after the fingers lifted): began or changed.
    case momentum
    /// The momentum ended or was cancelled: the scroll sequence is over (Chrome's
    /// `mouse_wheel_phase_handler.cc` closes the latching sequence here).
    case momentumEnded
}
