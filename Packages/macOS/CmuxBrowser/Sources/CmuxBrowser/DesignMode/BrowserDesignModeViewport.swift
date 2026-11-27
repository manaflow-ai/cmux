import Foundation

/// The CSS viewport size associated with a design-mode selection.
public struct BrowserDesignModeViewport: Codable, Equatable, Sendable {
    /// The viewport width.
    public let width: Double
    /// The viewport height.
    public let height: Double
    /// The page's horizontal scroll offset when the bounds were captured.
    public let scrollX: Double
    /// The page's vertical scroll offset when the bounds were captured.
    public let scrollY: Double

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case scrollX = "scroll_x"
        case scrollY = "scroll_y"
    }

    /// Creates a viewport size.
    /// - Parameters:
    ///   - width: The viewport width.
    ///   - height: The viewport height.
    ///   - scrollX: The horizontal page offset associated with selection bounds.
    ///   - scrollY: The vertical page offset associated with selection bounds.
    public init(
        width: Double,
        height: Double,
        scrollX: Double = 0,
        scrollY: Double = 0
    ) {
        self.width = width
        self.height = height
        self.scrollX = scrollX
        self.scrollY = scrollY
    }

    /// Decodes viewport dimensions and optional page scroll offsets.
    /// - Parameter decoder: The decoder containing viewport data.
    /// - Throws: A decoding error when either required viewport dimension is missing or invalid.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        scrollX = try container.decodeIfPresent(Double.self, forKey: .scrollX) ?? 0
        scrollY = try container.decodeIfPresent(Double.self, forKey: .scrollY) ?? 0
    }
}
