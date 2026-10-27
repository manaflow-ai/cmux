/// A set of ``InputEventType`` values as one bit mask: AppKit's `NSEvent.EventTypeMask` without
/// AppKit, for an observer that wants only some types of its classes (key-downs but not key-ups).
///
/// ```swift
/// subscription = input.observe(types: [.keyDown, .leftMouseDown, .scrollWheel]) { [weak self] _ in
///     self?.noteInput()
/// }
/// ```
public struct InputEventTypes: ExpressibleByArrayLiteral, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public init(arrayLiteral types: InputEventType...) {
        rawValue = types.reduce(0) { $0 | Self.bit($1) }
    }

    // perf-hot: 100ns main-turn (asked for every event an observe(types:) subscription hears)
    /// Whether the set holds `type`.
    public func contains(_ type: InputEventType) -> Bool { rawValue & Self.bit(type) != 0 }

    /// The classes of the set's types: what a subscription for them observes.
    public var classes: InputEventClasses {
        var classes: InputEventClasses = []
        var rest = rawValue
        while rest != 0 {
            let raw = UInt8(rest.trailingZeroBitCount)
            rest &= rest - 1
            if let type = InputEventType(rawValue: raw) { classes.insert(InputEventClasses(type.eventClass)) }
        }
        return classes
    }

    private static func bit(_ type: InputEventType) -> UInt32 { 1 << UInt32(type.rawValue) }
}

extension InputObserving {
    /// ``observe(_:windowNumber:_:)`` for exactly `types`: subscribes to their classes and skips the
    /// other types of those classes, as an AppKit local monitor's event mask did.
    ///
    /// - Parameters:
    ///   - types: The event types to receive.
    ///   - windowNumber: Only events whose window or owner window has this number; nil for every window.
    ///   - handler: Main-thread work for one event of `types`.
    /// - Returns: The subscription; keep it in a stored property.
    public func observe(types: InputEventTypes, windowNumber: Int? = nil,
                        _ handler: @escaping @MainActor (InputEventRecord) -> Void) -> InputSubscription {
        observe(types.classes, windowNumber: windowNumber) { record in
            if types.contains(record.type) { handler(record) }
        }
    }
}
