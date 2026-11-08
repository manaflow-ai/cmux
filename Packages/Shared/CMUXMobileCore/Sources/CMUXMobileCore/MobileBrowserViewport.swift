/// A phone browser viewport reported in CSS points and backing scale.
public struct MobileBrowserViewport: Codable, Equatable, Sendable {
    /// Viewport width in CSS points.
    public let width: Int
    /// Viewport height in CSS points.
    public let height: Int
    /// Phone display backing scale.
    public let scale: Double

    /// Creates a phone browser viewport report.
    /// - Parameters:
    ///   - width: Viewport width in CSS points.
    ///   - height: Viewport height in CSS points.
    ///   - scale: Phone display backing scale.
    public init(width: Int, height: Int, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }

    private enum CodingKeys: String, CodingKey {
        case width = "viewport_width"
        case height = "viewport_height"
        case scale = "viewport_scale"
    }
}
