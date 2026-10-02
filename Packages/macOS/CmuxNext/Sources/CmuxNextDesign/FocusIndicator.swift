public import CoreGraphics

/// `appearance.focusIndicator` in cmux.json: what marks the focused pane
/// when more than one shows. `border` draws the focus ring, `tabs` draws
/// the other panes' tabs subtler (a cue that needs no colored border, so it
/// also works with `appearance.borders` none), `both` does both, `none`
/// neither.
public nonisolated enum FocusIndicator: String, Sendable, CaseIterable, Codable, TunableChoice {
    case border
    case tabs
    case both
    case none

    /// Whether the focus ring may draw (`focusRing.*` still decides how).
    public var marksBorder: Bool { self == .border || self == .both }
    /// Whether unfocused panes' tabs draw subtler.
    public var marksTabs: Bool { self == .tabs || self == .both }

    public var tunableTitle: String {
        switch self {
        case .border: "Border"
        case .tabs: "Tabs"
        case .both: "Both"
        case .none: "None"
        }
    }
}

/// `appearance.tabBarBackground` in cmux.json: `window` paints no strip
/// fill, so the space around and between the tabs is the window's own
/// background (sidebar, titlebar and pane gaps); `darker` is a shade
/// darker than the window.
public nonisolated enum TabBarBackground: String, Sendable, CaseIterable, Codable, TunableChoice {
    case window
    case darker

    public var tunableTitle: String {
        switch self {
        case .window: "Window"
        case .darker: "Darker"
        }
    }
}

/// How an unfocused pane's tabs draw subtler (a Debug Settings prototype
/// switch; `fade` is the default).
public nonisolated enum InactiveTabStyle: String, Sendable, CaseIterable, Codable, TunableChoice {
    /// Text, icons and pill fills fade toward the background by the strength.
    case fade
    /// Every text tier steps down one tier; the selected pill takes the
    /// hover fill.
    case tonal
    /// No pill fill; the selected tab is marked by its text tier only.
    case quiet

    public var tunableTitle: String {
        switch self {
        case .fade: "Fade"
        case .tonal: "Tonal"
        case .quiet: "Quiet"
        }
    }
}

/// How strongly a pane's chrome (its tab strip) draws.
public nonisolated enum ChromeEmphasis: Hashable, Sendable {
    case full
    case subtle(InactiveTabStyle, strength: CGFloat)

    /// The emphasis for one pane's tabs: full for the focused pane, for the
    /// only pane, and when the indicator does not mark tabs; else subtle.
    public static func forPane(isFocused: Bool, paneCount: Int, indicator: FocusIndicator,
                               style: InactiveTabStyle, strength: CGFloat) -> ChromeEmphasis {
        .full
    }
}

/// The Debug Settings switches for the focus cue.
public nonisolated enum FocusIndicatorTunables {
    public static let indicator = Tunable<FocusIndicator>.choice(
        "focus.indicator", .focus, "Focus indicator",
        help: "What marks the focused pane (overrides appearance.focusIndicator in cmux.json).",
        default: .border, code: "FocusIndicatorTunables.indicator")
    public static let inactiveTabStyle = Tunable<InactiveTabStyle>.choice(
        "focus.inactiveTabStyle", .focus, "Unfocused pane tabs",
        help: "Prototype: how an unfocused pane's tabs draw subtler.",
        default: .fade, code: "FocusIndicatorTunables.inactiveTabStyle")
    public static let inactiveTabStrength = Tunable<CGFloat>.number(
        "focus.inactiveTabStrength", .focus, "Unfocused tabs strength",
        help: "How much subtler an unfocused pane's tabs draw (0 is the same as the focused pane).",
        default: 0.45, range: 0...1, step: 0.05, unit: .fraction, code: "FocusIndicatorTunables.inactiveTabStrength")
    public static let tabBarBackground = Tunable<TabBarBackground>.choice(
        "focus.tabBarBackground", .focus, "Tab bar background",
        help: "Overrides appearance.tabBarBackground in cmux.json.",
        default: .darker, code: "FocusIndicatorTunables.tabBarBackground")

    public static var all: [TunableDescriptor] {
        [indicator.descriptor, inactiveTabStyle.descriptor, inactiveTabStrength.descriptor, tabBarBackground.descriptor]
    }
}

extension ThemeTokens {
    /// These tokens with a pane's chrome emphasis applied: lower-contrast
    /// text and pill fills for a subtle pane, the same hues (no accent).
    public nonisolated func emphasized(_ emphasis: ChromeEmphasis) -> ThemeTokens {
        self
    }
}
