/// A pane rectangle in normalized workspace-hub coordinates.
public struct WorkspaceHubPaneFrame: Equatable, Sendable {
    /// The horizontal origin in the `0...1` workspace range.
    public let x: Double
    /// The vertical origin in the `0...1` workspace range.
    public let y: Double
    /// The pane width as a fraction of the workspace width.
    public let width: Double
    /// The pane height as a fraction of the workspace height.
    public let height: Double

    /// The full normalized workspace bounds.
    public static let unit = WorkspaceHubPaneFrame(x: 0, y: 0, width: 1, height: 1)

    /// Creates a normalized pane rectangle.
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
}
