public import CMUXMobileCore
internal import Foundation

/// The resolved appearance supplied to a terminal runtime when it creates or refreshes a surface.
public struct TerminalRuntimeAppearance: Codable, Equatable, Sendable {
    /// The primary terminal font family.
    public let fontFamily: String

    /// The terminal font size in points.
    public let fontSizePoints: Float32

    /// The resolved terminal colors and ANSI palette.
    public let theme: TerminalTheme

    /// Creates a validated runtime appearance.
    ///
    /// - Parameters:
    ///   - fontFamily: The primary terminal font family.
    ///   - fontSizePoints: The terminal font size in points.
    ///   - theme: The resolved terminal colors and ANSI palette.
    public init(
        fontFamily: String,
        fontSizePoints: Float32,
        theme: TerminalTheme
    ) {
        let trimmedFontFamily = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fontFamily = trimmedFontFamily.isEmpty ? "Menlo" : trimmedFontFamily
        self.fontSizePoints = fontSizePoints.isFinite && fontSizePoints > 0
            ? fontSizePoints
            : 12
        self.theme = theme.validatedOrDefault()
    }

    /// Returns an appearance with a valid surface-local font-size override applied.
    func applyingFontSizeOverride(_ fontSizePoints: Float32) -> TerminalRuntimeAppearance {
        guard fontSizePoints.isFinite, fontSizePoints > 0 else { return self }
        return TerminalRuntimeAppearance(
            fontFamily: fontFamily,
            fontSizePoints: fontSizePoints,
            theme: theme
        )
    }
}
