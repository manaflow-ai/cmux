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

/// Pure helpers backing the per-workspace/per-tab terminal badge overlay.
///
/// All logic here is presentation-independent so it can be unit tested without
/// AppKit/SwiftUI: template-token substitution and clamping of the numeric
/// style values to their valid ranges. The macOS app reads these alongside the
/// ``TerminalCatalogSection`` keys to build the rendered overlay.
public enum TerminalBadge {
    /// Template token replaced with the owning workspace's display title.
    public static let workspaceToken = "{workspace}"
    /// Template token replaced with the surface/tab's display title.
    public static let tabToken = "{tab}"

    /// Default template rendered when the badge is enabled.
    public static let defaultTemplate = "{workspace} · {tab}"

    /// Allowed opacity range for the badge text.
    public static let minOpacity = 0.05
    public static let maxOpacity = 1.0
    public static let defaultOpacity = 0.45

    /// Allowed font-size range (points) for the badge text.
    public static let minFontSize = 10.0
    public static let maxFontSize = 64.0
    public static let defaultFontSize = 24.0

    /// Default badge text color, a `#RRGGBB` hex string.
    public static let defaultColorHex = "#FFFFFF"

    /// Resolves a badge template against a workspace and tab title.
    ///
    /// `{workspace}` and `{tab}` tokens are substituted; any other text passes
    /// through verbatim. The result is trimmed of surrounding whitespace so an
    /// empty token (e.g. an unnamed surface) does not leave dangling spaces or
    /// separators at the edges. Returns an empty string when nothing remains,
    /// which the caller treats as "no badge to draw".
    public static func resolveText(
        template: String,
        workspace: String,
        tab: String
    ) -> String {
        let substituted = template
            .replacingOccurrences(of: workspaceToken, with: workspace)
            .replacingOccurrences(of: tabToken, with: tab)
        return substituted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clamps a stored opacity into the supported range.
    public static func clampOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultOpacity }
        return min(max(value, minOpacity), maxOpacity)
    }

    /// Clamps a stored font size into the supported range.
    public static func clampFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultFontSize }
        return min(max(value, minFontSize), maxFontSize)
    }
}
