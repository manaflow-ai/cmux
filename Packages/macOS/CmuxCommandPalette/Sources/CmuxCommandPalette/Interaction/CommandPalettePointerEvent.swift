public import CoreGraphics

/// A mouse-down snapshot used to decide whether a visible command palette should dismiss.
public struct CommandPalettePointerEvent: Sendable, Equatable {
    /// Whether the event belongs to the palette's observed window.
    public let isInObservedWindow: Bool

    /// The pointer location in the receiving window's coordinate space.
    public let locationInWindow: CGPoint

    /// Creates a pointer snapshot for palette interaction routing.
    ///
    /// - Parameters:
    ///   - isInObservedWindow: Whether the event belongs to the observed window.
    ///   - locationInWindow: The pointer location in window coordinates.
    public init(isInObservedWindow: Bool, locationInWindow: CGPoint) {
        self.isInObservedWindow = isInObservedWindow
        self.locationInWindow = locationInWindow
    }
}
