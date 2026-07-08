public import Foundation

/// A mouse or scroll event forwarded to a Chromium session.
///
/// Coordinates are view-local points with a top-left origin, matching Blink
/// widget coordinates. Modifiers are raw `NSEvent.ModifierFlags` bits; the
/// shell translates them to Blink modifiers.
public struct ChromiumMouseEvent: Sendable, Equatable {
    /// The wire values of `OwlFreshMouseKind`.
    public enum Kind: UInt32, Sendable {
        /// Button pressed.
        case down = 0
        /// Button released.
        case up = 1
        /// Pointer moved (with or without a button held).
        case move = 2
        /// Scroll wheel; deltas are precise pixels.
        case wheel = 3
    }

    /// The wire values Blink uses for mouse buttons.
    public enum Button: UInt32, Sendable {
        /// Primary button.
        case left = 0
        /// Middle button.
        case middle = 1
        /// Secondary button.
        case right = 2
    }

    /// What happened.
    public let kind: Kind
    /// Pointer x in view points from the left edge.
    public let x: Float
    /// Pointer y in view points from the top edge.
    public let y: Float
    /// Which button, for ``Kind/down``/``Kind/up`` (and drags).
    public let button: Button
    /// Click count for down/up events (double-click support).
    public let clickCount: UInt32
    /// Horizontal scroll delta in pixels, for ``Kind/wheel``.
    public let deltaX: Float
    /// Vertical scroll delta in pixels, for ``Kind/wheel``.
    public let deltaY: Float
    /// Raw `NSEvent.ModifierFlags` bits active during the event.
    public let modifiers: UInt32

    /// Creates a mouse event.
    ///
    /// - Parameters:
    ///   - kind: What happened.
    ///   - x: Pointer x in view points from the left edge.
    ///   - y: Pointer y in view points from the top edge.
    ///   - button: Which button; defaults to ``Button/left``.
    ///   - clickCount: Click count; defaults to 0 (moves and wheels).
    ///   - deltaX: Horizontal scroll delta; wheel events only.
    ///   - deltaY: Vertical scroll delta; wheel events only.
    ///   - modifiers: Raw `NSEvent.ModifierFlags` bits; defaults to none.
    public init(
        kind: Kind,
        x: Float,
        y: Float,
        button: Button = .left,
        clickCount: UInt32 = 0,
        deltaX: Float = 0,
        deltaY: Float = 0,
        modifiers: UInt32 = 0
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.clickCount = clickCount
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.modifiers = modifiers
    }
}
