public import AppKit
public import Foundation

/// A value identity for a single plain-Escape `NSEvent` reaching browser focus
/// mode, used to detect the duplicate deliveries AppKit produces when the same
/// physical key event is dispatched through more than one responder path.
///
/// Two events that share this fingerprint are the same delivery and must be
/// collapsed (the machine consumes the duplicate rather than counting it toward
/// the double-Escape exit). The modifier mask is normalized exactly as the
/// focus-mode key handler normalizes it (device-independent flags minus
/// numeric-pad, function, and caps-lock) so a fingerprint built from the raw
/// event matches the plain-Escape classification the machine performs.
public struct BrowserFocusModePlainEscapeEventFingerprint: Sendable, Equatable {
    /// The event phase (`keyDown`, `keyUp`, etc.).
    public let type: NSEvent.EventType

    /// The event's hardware timestamp.
    public let timestamp: TimeInterval

    /// The window the event was routed to.
    public let windowNumber: Int

    /// The hardware key code (53 for Escape).
    public let keyCode: UInt16

    /// The normalized device-independent modifier flags, with numeric-pad,
    /// function, and caps-lock removed.
    public let modifierFlags: NSEvent.ModifierFlags.RawValue

    /// Builds a fingerprint from a delivered key event, normalizing the modifier
    /// flags identically to the focus-mode plain-Escape classifier.
    public init(_ event: NSEvent) {
        self.type = event.type
        self.timestamp = event.timestamp
        self.windowNumber = event.windowNumber
        self.keyCode = event.keyCode
        self.modifierFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
            .rawValue
    }
}
