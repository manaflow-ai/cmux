/// A pointer interaction forwarded from the host's sidebar surface to the
/// render worker, which replays it against its offscreen view tree.
///
/// Coordinates are in points in the surface's AppKit window space: origin at
/// the **bottom-left** of the sidebar surface, matching the worker's offscreen
/// window so no flipping is needed on either side.
public struct RenderPointerEvent: Codable, Sendable, Equatable {
    /// The interaction kind.
    public enum Kind: String, Codable, Sendable {
        /// Primary button pressed.
        case down
        /// Primary button released.
        case up
        /// Pointer moved with the primary button held.
        case drag
        /// Scroll wheel / trackpad scroll delta.
        case scroll
    }

    /// What happened.
    public var kind: Kind
    /// X in surface points, from the left edge.
    public var x: Double
    /// Y in surface points, from the **bottom** edge (AppKit window coords).
    public var y: Double
    /// Horizontal scroll delta in points (``Kind/scroll`` only).
    public var deltaX: Double
    /// Vertical scroll delta in points (``Kind/scroll`` only).
    public var deltaY: Double
    /// Click multiplicity for ``Kind/down``/``Kind/up`` (double-click = 2).
    public var clickCount: Int

    /// Creates a pointer event.
    ///
    /// - Parameters:
    ///   - kind: The interaction kind.
    ///   - x: X in surface points from the left edge.
    ///   - y: Y in surface points from the bottom edge.
    ///   - deltaX: Horizontal scroll delta (scroll only).
    ///   - deltaY: Vertical scroll delta (scroll only).
    ///   - clickCount: Click multiplicity for down/up.
    public init(
        kind: Kind,
        x: Double,
        y: Double,
        deltaX: Double = 0,
        deltaY: Double = 0,
        clickCount: Int = 1
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.clickCount = clickCount
    }
}
