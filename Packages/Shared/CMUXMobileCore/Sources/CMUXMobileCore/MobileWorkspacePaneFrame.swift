/// A pane rectangle in unit coordinates relative to its workspace layout.
public struct MobileWorkspacePaneFrame: Codable, Equatable, Sendable {
    /// The horizontal origin in the closed interval `0...1`.
    public var x: Double
    /// The vertical origin in the closed interval `0...1`.
    public var y: Double
    /// The pane width as a fraction of the workspace width.
    public var width: Double
    /// The pane height as a fraction of the workspace height.
    public var height: Double

    /// Creates a unit-coordinate pane frame.
    /// - Parameters:
    ///   - x: The horizontal origin.
    ///   - y: The vertical origin.
    ///   - width: The fractional width.
    ///   - height: The fractional height.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The full workspace bounds.
    public static let unit = MobileWorkspacePaneFrame(x: 0, y: 0, width: 1, height: 1)
}
