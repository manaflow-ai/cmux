/// A normalized participant cursor position within a shared pane.
public struct ShareCursorPos: Codable, Equatable, Sendable {
    /// Wire workspace identifier.
    public var ws: String

    /// Wire pane identifier.
    public var pane: String

    /// Horizontal position normalized to `0...1`.
    public var x: Double

    /// Vertical position normalized to `0...1`.
    public var y: Double

    /// Creates a normalized cursor position.
    ///
    /// - Parameters:
    ///   - ws: Wire workspace identifier.
    ///   - pane: Wire pane identifier.
    ///   - x: Horizontal normalized position.
    ///   - y: Vertical normalized position.
    public init(ws: String, pane: String, x: Double, y: Double) {
        self.ws = ws
        self.pane = pane
        self.x = x
        self.y = y
    }
}
