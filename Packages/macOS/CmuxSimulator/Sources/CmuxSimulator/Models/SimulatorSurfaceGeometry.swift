/// The host pane geometry sent to the remote renderer.
public struct SimulatorSurfaceGeometry: Codable, Equatable, Sendable {
    /// The pane width in points.
    public let width: Double
    /// The pane height in points.
    public let height: Double
    /// The host window backing scale.
    public let scale: Double

    /// Creates a host-surface geometry snapshot.
    public init(width: Double, height: Double, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }
}
