public import CoreGraphics

/// A trusted input event an automation client sends to a page.
///
/// Only engines with ``BrowserEngineCapabilities/trustedInput`` accept these;
/// the others throw ``BrowserEngineError/unsupported(_:)``.
public enum BrowserPageInputEvent: Equatable, Hashable, Sendable {
    /// A mouse button.
    public enum MouseButton: Equatable, Hashable, Sendable {
        /// The primary button.
        case left
        /// The secondary button.
        case right
        /// The middle button.
        case middle
    }

    /// Modifier keys held during an event.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        /// The raw bit set.
        public let rawValue: UInt8
        /// Creates modifiers from raw bits.
        /// - Parameter rawValue: The bit set.
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// Shift.
        public static let shift = Modifiers(rawValue: 1 << 0)
        /// Control.
        public static let control = Modifiers(rawValue: 1 << 1)
        /// Option.
        public static let option = Modifiers(rawValue: 1 << 2)
        /// Command.
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// A click at a point in page (CSS pixel) coordinates.
    case click(at: CGPoint, button: MouseButton, clickCount: Int, modifiers: Modifiers)
    /// The pointer moves to a point in page coordinates.
    case mouseMove(to: CGPoint, modifiers: Modifiers)
    /// A wheel scroll at a point, in page pixels.
    case scroll(at: CGPoint, deltaX: Double, deltaY: Double)
    /// A key press, by DOM `key` value (for example `Enter`, `a`).
    case key(String, modifiers: Modifiers)
    /// Text inserted as if typed or committed by an input method.
    case insertText(String)
}
