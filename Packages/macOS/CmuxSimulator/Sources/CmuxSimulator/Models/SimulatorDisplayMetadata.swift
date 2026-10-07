/// Metadata describing the current simulated display surface.
public struct SimulatorDisplayMetadata: Codable, Equatable, Sendable {
    /// The framebuffer width in pixels.
    public let width: Int
    /// The framebuffer height in pixels.
    public let height: Int
    /// The current logical device orientation.
    public let orientation: SimulatorOrientation
    /// The device's pixels-per-point scale when known.
    public let scale: Double

    /// Creates display metadata.
    public init(width: Int, height: Int, orientation: SimulatorOrientation, scale: Double) {
        self.width = width
        self.height = height
        self.orientation = orientation
        self.scale = scale
    }
}
