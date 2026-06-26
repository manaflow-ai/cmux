import Foundation

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
    /// Default badge text opacity.
    public static let defaultOpacity = 0.45

    /// Supported font-size range (points) for the badge text.
    public static let fontSizeRange: ClosedRange<Double> = 10.0...64.0
    /// Default badge font size in points.
    public static let defaultFontSize = 24.0

    /// Default badge text color, a `#RRGGBB` hex string.
    public static let defaultColorHex = "#FFFFFF"

    /// Maximum length of the stored template. The template comes from settings
    /// (UserDefaults / cmux.json) and is bounded on init so a malformed value
    /// cannot force large scans/allocations when it is later substituted.
    public static let maxTemplateLength = 512
    /// Maximum length of each substituted token value. The tab title is driven
    /// by terminal escape sequences and is otherwise unbounded, so it is capped
    /// before substitution to keep a hostile/buggy process from forcing large
    /// allocations or text layout on the terminal update path.
    public static let maxTokenLength = 128
    /// Maximum length of the fully resolved badge text rendered in the overlay.
    public static let maxResolvedLength = 256

    /// The badge template, e.g. `"{workspace} · {tab}"`.
    public let template: String
    /// The corner the badge is anchored to.
    public let position: TerminalBadgePosition
    /// Badge text opacity, clamped to ``opacityRange``.
    public let opacity: Double
    /// Badge text size in points, clamped to ``fontSizeRange``.
    public let fontSize: Double
    /// Badge text color as a `#RRGGBB` hex string.
    public let colorHex: String

    /// Creates a configuration, clamping `opacity` and `fontSize` into their
    /// supported ranges (non-finite values fall back to the defaults).
    public init(
        template: String = TerminalBadgeConfiguration.defaultTemplate,
        position: TerminalBadgePosition = .topTrailing,
        opacity: Double = TerminalBadgeConfiguration.defaultOpacity,
        fontSize: Double = TerminalBadgeConfiguration.defaultFontSize,
        colorHex: String = TerminalBadgeConfiguration.defaultColorHex
    ) {
        self.template = String(template.prefix(Self.maxTemplateLength))
        self.position = position
        self.opacity = clampedTerminalBadgeValue(
            opacity, in: Self.opacityRange, fallback: Self.defaultOpacity
        )
        self.fontSize = clampedTerminalBadgeValue(
            fontSize, in: Self.fontSizeRange, fallback: Self.defaultFontSize
        )
        self.colorHex = colorHex
    }

    /// Resolves the template against a workspace and tab title.
    ///
    /// `{workspace}` and `{tab}` tokens are substituted; any other text passes
    /// through verbatim, then surrounding whitespace is trimmed. When the
    /// template is built from tokens and every token it uses resolves to empty
    /// — so only literal separators like `" · "` would remain — an empty string
    /// is returned, which the caller treats as "no badge to draw". A template
    /// with no tokens (pure literal text) always renders as-is.
    ///
    /// The terminal-controlled tab title is bounded to ``maxTokenLength`` before
    /// substitution and the final result to ``maxResolvedLength``, so a process
    /// emitting a very large title cannot force unbounded allocation or text
    /// layout on the terminal update path.
    public func resolvedText(workspace: String, tab: String) -> String {
        let boundedWorkspace = String(workspace.prefix(Self.maxTokenLength))
        let boundedTab = String(tab.prefix(Self.maxTokenLength))
        let usesWorkspace = template.contains(Self.workspaceToken)
        let usesTab = template.contains(Self.tabToken)
        let workspaceEmpty = boundedWorkspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let tabEmpty = boundedTab.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let usesAnyToken = usesWorkspace || usesTab
        let everyUsedTokenEmpty = !(usesWorkspace && !workspaceEmpty) && !(usesTab && !tabEmpty)
        if usesAnyToken, everyUsedTokenEmpty {
            return ""
        }
        let resolved = template
            .replacingOccurrences(of: Self.workspaceToken, with: boundedWorkspace)
            .replacingOccurrences(of: Self.tabToken, with: boundedTab)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(resolved.prefix(Self.maxResolvedLength))
    }
}

/// Clamps `value` into `range`, falling back to `fallback` for non-finite input.
private func clampedTerminalBadgeValue(
    _ value: Double,
    in range: ClosedRange<Double>,
    fallback: Double
) -> Double {
    guard value.isFinite else { return fallback }
    return min(max(value, range.lowerBound), range.upperBound)
}
