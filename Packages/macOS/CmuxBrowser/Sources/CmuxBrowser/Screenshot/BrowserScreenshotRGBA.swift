public import AppKit

/// A normalized sRGB pixel color used by browser screenshot verification.
public struct BrowserScreenshotRGBA: Equatable, Sendable {
    /// Red component, normalized to `0...1`.
    public let red: CGFloat
    /// Green component, normalized to `0...1`.
    public let green: CGFloat
    /// Blue component, normalized to `0...1`.
    public let blue: CGFloat
    /// Alpha component, normalized to `0...1`.
    public let alpha: CGFloat

    /// Opaque black.
    public static let black = BrowserScreenshotRGBA(red: 0, green: 0, blue: 0, alpha: 1)
    /// Opaque white.
    public static let white = BrowserScreenshotRGBA(red: 1, green: 1, blue: 1, alpha: 1)

    /// Creates a normalized sRGB color.
    ///
    /// - Parameters:
    ///   - red: Red component.
    ///   - green: Green component.
    ///   - blue: Blue component.
    ///   - alpha: Alpha component.
    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Returns the largest normalized channel difference from another color.
    ///
    /// - Parameter other: The color to compare.
    /// - Returns: The largest absolute channel difference.
    func distance(from other: BrowserScreenshotRGBA) -> CGFloat {
        max(
            abs(red - other.red),
            abs(green - other.green),
            abs(blue - other.blue),
            abs(alpha - other.alpha)
        )
    }
}
