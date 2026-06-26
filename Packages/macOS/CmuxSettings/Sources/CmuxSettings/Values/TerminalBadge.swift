import Foundation

/// Corner of the terminal surface where the scroll-fixed badge overlay is
/// anchored. Stored under ``TerminalCatalogSection/badgePosition``.
///
/// Cases use leading/trailing semantics so the anchor automatically mirrors
/// for right-to-left layouts; the settings UI presents them with left/right
/// labels for the languages cmux currently ships.
public enum TerminalBadgePosition: String, CaseIterable, Sendable, SettingCodable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

/// A validated configuration for the per-workspace/per-tab terminal badge
/// overlay (an iTerm2-style watermark).
///
/// This is an instantiable value, not a static-helper namespace: numeric
/// fields are clamped to their supported ranges on `init`, and the template is
/// resolved against a concrete workspace/tab pair via ``resolvedText(workspace:tab:)``.
/// Keeping the logic on the value keeps it presentation-independent and unit
/// testable without AppKit/SwiftUI; the macOS app builds one from the live
/// ``TerminalCatalogSection`` settings to render the overlay.
public struct TerminalBadgeConfiguration: Equatable, Sendable {
    /// Template token replaced with the owning workspace's display title.
    public static let workspaceToken = "{workspace}"
    /// Template token replaced with the surface/tab's display title.
    public static let tabToken = "{tab}"
    /// Default template rendered when the badge is enabled.
    public static let defaultTemplate = "{workspace} · {tab}"

    /// Supported opacity range for the badge text.
    public static let opacityRange: ClosedRange<Double> = 0.05...1.0
    public static let defaultOpacity = 0.45

    /// Supported font-size range (points) for the badge text.
    public static let fontSizeRange: ClosedRange<Double> = 10.0...64.0
    public static let defaultFontSize = 24.0

    /// Default badge text color, a `#RRGGBB` hex string.
    public static let defaultColorHex = "#FFFFFF"

    public let template: String
    public let position: TerminalBadgePosition
    /// Clamped to ``opacityRange``.
    public let opacity: Double
    /// Clamped to ``fontSizeRange``.
    public let fontSize: Double
    public let colorHex: String

    public init(
        template: String = TerminalBadgeConfiguration.defaultTemplate,
        position: TerminalBadgePosition = .topTrailing,
        opacity: Double = TerminalBadgeConfiguration.defaultOpacity,
        fontSize: Double = TerminalBadgeConfiguration.defaultFontSize,
        colorHex: String = TerminalBadgeConfiguration.defaultColorHex
    ) {
        self.template = template
        self.position = position
        self.opacity = Self.clamped(opacity, in: Self.opacityRange, fallback: Self.defaultOpacity)
        self.fontSize = Self.clamped(fontSize, in: Self.fontSizeRange, fallback: Self.defaultFontSize)
        self.colorHex = colorHex
    }

    /// Resolves the template against a workspace and tab title.
    ///
    /// `{workspace}` and `{tab}` tokens are substituted; any other text passes
    /// through verbatim. The result is trimmed of surrounding whitespace so an
    /// empty token (e.g. an unnamed surface) does not leave dangling spaces or
    /// separators at the edges. An empty result means "no badge to draw".
    public func resolvedText(workspace: String, tab: String) -> String {
        template
            .replacingOccurrences(of: Self.workspaceToken, with: workspace)
            .replacingOccurrences(of: Self.tabToken, with: tab)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clamped(
        _ value: Double,
        in range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
