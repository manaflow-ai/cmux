/// The classes of input event a subscription of the app's one input tap asks for
/// (plans/cmux-next/chrome-parity/p04-input.md section 3 (A)). The tap keeps one list per class,
/// so an event costs only the subscribers of its own class.
public enum InputEventClass: UInt8, CaseIterable, Hashable, Sendable {
    /// Key down and key up.
    case key
    /// A modifier key changed (`flagsChanged`).
    case flags
    /// A mouse button went down or up.
    case button
    /// The pointer moved with no button down.
    case pointerMove
    /// The pointer moved with a button down.
    case drag
    /// A scroll wheel or trackpad scroll, momentum included.
    case scroll
    /// A trackpad gesture: magnify, rotate, swipe, smart magnify, pressure.
    case gesture
    /// The pointer crossed a tracking area's edge (`mouseEntered`, `mouseExited`): a window that does
    /// not take mouse moves sends only these as the pointer moves over it. Not in ``InputEventClasses/all``
    /// or ``InputEventClasses/pointer``: only an owner that names it hears it.
    case tracking
}

/// A set of ``InputEventClass`` values: what one subscription receives.
public struct InputEventClasses: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The set holding only `eventClass`.
    public init(_ eventClass: InputEventClass) { rawValue = 1 << eventClass.rawValue }

    public static let key = InputEventClasses(.key)
    public static let flags = InputEventClasses(.flags)
    public static let button = InputEventClasses(.button)
    public static let pointerMove = InputEventClasses(.pointerMove)
    public static let drag = InputEventClasses(.drag)
    public static let scroll = InputEventClasses(.scroll)
    public static let gesture = InputEventClasses(.gesture)
    public static let tracking = InputEventClasses(.tracking)
    /// Every pointer class: buttons, moves, drags and scrolls.
    public static let pointer: InputEventClasses = [.button, .pointerMove, .drag, .scroll]
    /// Every class of a person's input (not ``tracking``, which a move makes).
    public static let all: InputEventClasses = [.key, .flags, .button, .pointerMove, .drag, .scroll, .gesture]

    /// Whether the set holds `eventClass`.
    public func contains(_ eventClass: InputEventClass) -> Bool { rawValue & (1 << eventClass.rawValue) != 0 }
}
