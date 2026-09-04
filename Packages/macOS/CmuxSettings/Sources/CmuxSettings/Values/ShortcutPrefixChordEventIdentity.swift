import Foundation

/// Stable identity for one physical key event as it crosses AppKit routing layers.
///
/// AppKit and WebKit can replay an event as a distinct ``NSEvent`` instance. Key
/// events do not expose a supported AppKit event number, so hosts use the
/// structural fields below to recognize an in-flight replay. Synthetic events
/// may also use `0`; the complete tuple remains a conservative identity.
public struct ShortcutPrefixChordEventIdentity: Sendable, Equatable, Hashable {
    /// An optional platform event number for event kinds that provide one; key
    /// events use `0` because AppKit does not define `eventNumber` for them.
    public let eventNumber: UInt64
    /// Window in which the event was observed, when known.
    public let windowID: Int?
    /// Virtual key code carried by the event.
    public let keyCode: UInt16
    /// Raw modifier flags carried by the event.
    public let modifierFlags: UInt
    /// Event timestamp used as a structural fallback for synthetic events.
    public let timestamp: TimeInterval

    /// Creates an event identity from platform event fields.
    ///
    /// Non-finite timestamps are normalized to zero so malformed synthetic
    /// events cannot poison hashing or ordering in a host ledger.
    public init(
        eventNumber: UInt64 = 0,
        windowID: Int? = nil,
        keyCode: UInt16,
        modifierFlags: UInt,
        timestamp: TimeInterval
    ) {
        self.eventNumber = eventNumber
        self.windowID = windowID
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.timestamp = timestamp.isFinite ? timestamp : 0
    }

    /// Nonzero platform event numbers are authoritative when a host supplies
    /// them. Keyboard and synthetic events use the complete structural tuple.
    public static func == (
        lhs: ShortcutPrefixChordEventIdentity,
        rhs: ShortcutPrefixChordEventIdentity
    ) -> Bool {
        if lhs.eventNumber != 0 || rhs.eventNumber != 0 {
            return lhs.eventNumber != 0
                && lhs.eventNumber == rhs.eventNumber
        }
        return lhs.windowID == rhs.windowID
            && lhs.keyCode == rhs.keyCode
            && lhs.modifierFlags == rhs.modifierFlags
            && lhs.timestamp == rhs.timestamp
    }

    public func hash(into hasher: inout Hasher) {
        if eventNumber != 0 {
            hasher.combine(eventNumber)
            return
        }
        hasher.combine(eventNumber)
        hasher.combine(windowID)
        hasher.combine(keyCode)
        hasher.combine(modifierFlags)
        hasher.combine(timestamp)
    }
}
