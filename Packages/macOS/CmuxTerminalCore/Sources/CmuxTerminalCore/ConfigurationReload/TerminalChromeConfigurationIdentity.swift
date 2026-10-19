internal import AppKit

/// Identity of Ghostty values consumed by persistent workspace and Dock chrome.
public struct TerminalChromeConfigurationIdentity: Equatable, Sendable {
    private let backgroundColorHex: String
    private let foregroundColorHex: String
    private let backgroundOpacity: Double
    private let surfaceTabBarFontSize: CGFloat
    private let unfocusedSplitOpacity: Double
    private let unfocusedSplitFillHex: String?
    private let splitDividerColorHex: String?
    private let usesHostLayerBackground: Bool

    /// Captures the config fields that require scoped chrome invalidation.
    ///
    /// - Parameters:
    ///   - configuration: The resolved Ghostty configuration.
    ///   - usesHostLayerBackground: Whether the host layer owns the terminal
    ///     background instead of Ghostty's renderer.
    public init(
        configuration: GhosttyConfig,
        usesHostLayerBackground: Bool
    ) {
        backgroundColorHex = configuration.backgroundColor.hexString(includeAlpha: true)
        foregroundColorHex = configuration.foregroundColor.hexString(includeAlpha: true)
        backgroundOpacity = configuration.backgroundOpacity
        surfaceTabBarFontSize = configuration.surfaceTabBarFontSize
        unfocusedSplitOpacity = configuration.unfocusedSplitOpacity
        unfocusedSplitFillHex = configuration.unfocusedSplitFill?
            .hexString(includeAlpha: true)
        splitDividerColorHex = configuration.splitDividerColor?
            .hexString(includeAlpha: true)
        self.usesHostLayerBackground = usesHostLayerBackground
    }
}
