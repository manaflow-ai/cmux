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

    /// Returns whether this event is known to be outside the visible palette.
    ///
    /// An unmounted panel marker produces `nil`. That transient geometry state is
    /// not evidence of an outside click, so events in the observed window keep the
    /// palette open until its panel bounds are available.
    ///
    /// - Parameter panelContainsPoint: Whether the mounted panel contains the event.
    /// - Returns: `true` only for another window or a known-outside panel point.
    public func shouldDismissPalette(panelContainsPoint: Bool?) -> Bool {
        guard isInObservedWindow else { return true }
        return panelContainsPoint == false
    }
}
