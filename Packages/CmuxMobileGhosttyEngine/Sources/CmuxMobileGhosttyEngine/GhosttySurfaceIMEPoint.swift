/// The IME caret rectangle reported by libghostty, in surface-local points.
public struct GhosttySurfaceIMEPoint: Sendable, Equatable {
    /// X origin in points.
    public let x: Double
    /// Y origin in points.
    public let y: Double
    /// Width in points.
    public let width: Double
    /// Height in points.
    public let height: Double

    /// Creates an IME point.
    /// - Parameters:
    ///   - x: X origin in points.
    ///   - y: Y origin in points.
    ///   - width: Width in points.
    ///   - height: Height in points.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
