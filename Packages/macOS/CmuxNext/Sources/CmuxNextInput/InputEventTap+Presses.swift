public import AppKit

// Presses: key-downs and mouse-downs, the events that say a person acted (the no-activate guard's
// input signal, the click work after dispatch), so owners do not each filter the event types again.
extension InputEventTap {
    /// The kinds of press a ``subscribePresses(_:phase:while:handler:)`` subscription hears.
    public struct Presses: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// A key-down (repeats included).
        public static let keyDown = Presses(rawValue: 1 << 0)
        /// A mouse-down of any button.
        public static let mouseDown = Presses(rawValue: 1 << 1)

        /// Whether an event of `type` is one of these presses.
        public func matches(_ type: NSEvent.EventType) -> Bool {
            switch type {
            case .keyDown: contains(.keyDown)
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: contains(.mouseDown)
            default: false
            }
        }
    }

    /// Calls `handler` with each press of `presses` in `phase`, until the returned subscription is
    /// cancelled or released. Ups, flags, moves, drags and scrolls are not presses.
    ///
    /// - Parameters:
    ///   - presses: The presses to receive.
    ///   - phase: Before the key router (`observe`) or after AppKit dispatched the event (`afterDispatch`).
    ///   - active: Asked before each call; the handler runs only while it returns true. It must be O(1).
    ///   - handler: Main-thread work for one press.
    /// - Returns: The subscription; keep it in a stored property.
    public func subscribePresses(_ presses: Presses, phase: Phase = .observe, while active: (@MainActor () -> Bool)? = nil,
                                 handler: @escaping @MainActor (NSEvent) -> Void) -> InputSubscription {
        var classes: InputEventClasses = []
        if presses.contains(.keyDown) { classes.insert(.key) }
        if presses.contains(.mouseDown) { classes.insert(.button) }
        return subscribe(class: classes, phase: phase, while: active) { event in
            if presses.matches(event.type) { handler(event) }
        }
    }
}
