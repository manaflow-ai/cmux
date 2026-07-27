import Foundation

/// The CSS viewport size associated with a design-mode selection.
public struct BrowserDesignModeViewport: Codable, Equatable, Sendable {
    /// The viewport width.
    public let width: Double
    /// The viewport height.
    public let height: Double

    /// Creates a viewport size.
    /// - Parameters:
    ///   - width: The viewport width.
    ///   - height: The viewport height.
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}
