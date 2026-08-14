import Foundation

/// Resolves editor appearance from its effective foreground color.
public struct FilePreviewSyntaxAppearanceResolver: Sendable {
    /// Creates an appearance resolver.
    public init() {}

    /// Resolves the palette appearance from sRGB foreground components.
    ///
    /// A light foreground implies a dark editor background; a dark foreground implies a light
    /// background. This also follows custom terminal-derived themes whose content background is
    /// transparent and therefore cannot be inspected directly.
    ///
    /// - Parameters:
    ///   - red: sRGB red component in `0...1`.
    ///   - green: sRGB green component in `0...1`.
    ///   - blue: sRGB blue component in `0...1`.
    /// - Returns: The matching light or dark editor appearance.
    public func appearance(
        forForegroundRed red: Double,
        green: Double,
        blue: Double
    ) -> FilePreviewSyntaxAppearance {
        let luminance = 0.2126 * Self.linearized(red)
            + 0.7152 * Self.linearized(green)
            + 0.0722 * Self.linearized(blue)
        return luminance >= 0.5 ? .dark : .light
    }

    private static func linearized(_ component: Double) -> Double {
        if component <= 0.04045 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }
}
