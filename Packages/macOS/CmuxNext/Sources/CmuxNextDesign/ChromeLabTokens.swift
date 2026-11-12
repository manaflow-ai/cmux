public import CoreGraphics

/// A density's exact tab bar spacing and roundness (Lawrence 2026-11-12: the gap between the tab bar's + and ⋮ is too
/// wide; "i need to be able to adjust roundness ... concentric with macos window ideally, but i want to be able to play
/// around with it"). Keys in `DensityTokens.tokens`; an unset key keeps the derived value. The Density Lab sets them.
public nonisolated enum ChromeLabToken: String, CaseIterable, Sendable {
    /// The strip's leading and trailing padding around its tabs.
    case tabStripPadding
    /// The gap from the last tab to the strip's +.
    case newTabGap = "tabNewTabGap"
    /// The gap between the tab bar's trailing buttons.
    case toolbarGap = "tabToolbarGap"
    /// The tab bar ⋮'s distance from the pane's trailing edge.
    case toolbarTrailing = "tabToolbarTrailing"
    /// The radius of every tab, the omnibar and the sidebar's rows.
    case tabRadius = "tabCornerRadius"
    /// The radius of the main content card (the curved main pane).
    case cardRadius = "cardCornerRadius"

    /// The active density's value for this token at the interface scale, nil when it is not set.
    @MainActor public var value: CGFloat? { Metrics.tokens.tokens[rawValue].map { Metrics.scale(CGFloat($0)) } }
}
