/// The device-independent modifier keys of an event, with `NSEvent.ModifierFlags`' bit values
/// (the same as `CGEventFlags`), so a record converts back without a table.
public struct InputModifierFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let capsLock = InputModifierFlags(rawValue: 1 << 16)
    public static let shift = InputModifierFlags(rawValue: 1 << 17)
    public static let control = InputModifierFlags(rawValue: 1 << 18)
    public static let option = InputModifierFlags(rawValue: 1 << 19)
    public static let command = InputModifierFlags(rawValue: 1 << 20)
    public static let numericPad = InputModifierFlags(rawValue: 1 << 21)
    public static let help = InputModifierFlags(rawValue: 1 << 22)
    public static let function = InputModifierFlags(rawValue: 1 << 23)
    /// `NSEvent.ModifierFlags.deviceIndependentFlagsMask`.
    public static let deviceIndependentMask = InputModifierFlags(rawValue: 0xFFFF_0000)
}

/// A point in AppKit coordinates (origin bottom-left).
public struct InputPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = InputPoint(x: 0, y: 0)
}

/// One input event as a plain value: what core and service packages see of a person's input
/// (`InputObserving`), and what the tap keeps as its last dispatched and last pointer event. Only ui
/// packages see the `NSEvent`.
///
/// Fixed size and trivially copyable: building one allocates nothing, and a field that does not apply
/// to the event's type is zero.
public struct InputEventRecord: Hashable, Sendable {
    public var type: InputEventType
    /// When the event happened: seconds since boot, the clock of `NSEvent.timestamp`
    /// (`CLOCK_UPTIME_RAW`, stopped during sleep).
    public var timestamp: Double
    /// The window number of the event's window; 0 for none.
    public var windowNumber: Int
    /// The window number of the window that owns the event's window: the event's window, or the
    /// top of its parent chain below the first panel (a Chromium page window's cmux window); 0 for none.
    public var ownerWindowNumber: Int
    /// The pointer in the event's window (screen coordinates when it has none).
    public var location: InputPoint
    /// The pointer in screen coordinates.
    public var screenLocation: InputPoint
    public var modifierFlags: InputModifierFlags
    /// The virtual key code of a key or flags event; 0 otherwise.
    public var keyCode: UInt16
    /// A key down that repeats a held key.
    public var isRepeat: Bool
    /// The mouse button of a button or drag event (0 left, 1 right, 2 and up other); 0 otherwise.
    public var buttonNumber: Int
    /// The click count of a button event; 0 otherwise.
    public var clickCount: Int
    public var scrollPhase: InputScrollPhase
    /// The scroll distance of a scroll event; zero otherwise.
    public var scrollDelta: InputPoint
    /// The scroll delta is in points (a trackpad or Magic Mouse), not in lines.
    public var hasPreciseScrollingDeltas: Bool

    public init(type: InputEventType, timestamp: Double, windowNumber: Int = 0, ownerWindowNumber: Int = 0,
                location: InputPoint = .zero, screenLocation: InputPoint = .zero, modifierFlags: InputModifierFlags = [],
                keyCode: UInt16 = 0, isRepeat: Bool = false, buttonNumber: Int = 0, clickCount: Int = 0,
                scrollPhase: InputScrollPhase = .none, scrollDelta: InputPoint = .zero, hasPreciseScrollingDeltas: Bool = false) {
        self.type = type
        self.timestamp = timestamp
        self.windowNumber = windowNumber
        self.ownerWindowNumber = ownerWindowNumber
        self.location = location
        self.screenLocation = screenLocation
        self.modifierFlags = modifierFlags
        self.keyCode = keyCode
        self.isRepeat = isRepeat
        self.buttonNumber = buttonNumber
        self.clickCount = clickCount
        self.scrollPhase = scrollPhase
        self.scrollDelta = scrollDelta
        self.hasPreciseScrollingDeltas = hasPreciseScrollingDeltas
    }

    /// The class whose subscribers get this event.
    public var eventClass: InputEventClass { type.eventClass }
}
