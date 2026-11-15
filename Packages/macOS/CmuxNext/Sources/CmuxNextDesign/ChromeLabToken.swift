public import CoreGraphics

/// A density's exact chrome values the Density Lab sets (Lawrence 2026-11-12/15): every square chrome button one size
/// at every density, the toolbar icons' size and spacing, the tab bar's spacing and the corners. Keys in
/// `DensityTokens.tokens`; an unset key keeps the derived value, so a density without them draws as before.
public nonisolated enum ChromeLabToken: String, CaseIterable, Sendable {
    /// Every square chrome button: the sidebar toggle, Back, Forward, the sidebar's +, the tab bar's buttons and the
    /// browser toolbar's (reload, extensions).
    case buttonSize = "chromeButtonSize"
    /// The ink of every toolbar icon: back, forward, reload, extensions, the star, the top row's arrows and +.
    case iconInk = "chromeIconInk"
    /// The gap between the browser toolbar's buttons (back, forward, reload, extensions).
    case toolbarGap = "chromeToolbarGap"
    /// The gap between the top row's buttons (sidebar toggle, Back, Forward).
    case topRowGap = "chromeTopRowGap"
    /// The strip's leading and trailing padding around its tabs.
    case tabStripPadding = "tabStripPadding"
    /// The gap from the last tab to the strip's +.
    case newTabGap = "tabNewTabGap"
    /// The room after the tab bar's + (or its last tab), before its trailing buttons (the ⋮).
    case spaceAfterPlus = "tabSpaceAfterPlus"
    /// The gap between the tab bar's trailing buttons (pins, Exit Zoom, ⋮).
    case tabButtonGap = "tabButtonGap"
    /// The tab bar ⋮'s distance from the pane's trailing edge.
    case tabTrailing = "tabTrailing"
    /// The radius of every tab, the omnibar, buttons and the sidebar's rows.
    case tabRadius = "tabCornerRadius"
    /// The radius of the main content card (the curved main pane).
    case cardRadius = "cardCornerRadius"

    /// The active density's value at the interface scale, nil when it is not set.
    @MainActor public var value: CGFloat? { Metrics.tokens.tokens[rawValue].map { Metrics.scale(CGFloat($0)) } }

    /// The tokens that may be negative (offsets, not sizes); none today.
    public static let signed: Set<String> = []
}
