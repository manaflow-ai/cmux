/// A pane rectangle normalized to its workspace bounds.
public struct MobilePaneNormalizedRect: Equatable, Sendable {
    /// Horizontal origin in normalized workspace coordinates.
    public var x: Double
    /// Vertical origin in normalized workspace coordinates.
    public var y: Double
    /// Normalized pane width.
    public var w: Double
    /// Normalized pane height.
    public var h: Double

    /// Creates a normalized pane rectangle.
    /// - Parameters:
    ///   - x: Horizontal origin in normalized workspace coordinates.
    ///   - y: Vertical origin in normalized workspace coordinates.
    ///   - w: Normalized pane width.
    ///   - h: Normalized pane height.
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}
