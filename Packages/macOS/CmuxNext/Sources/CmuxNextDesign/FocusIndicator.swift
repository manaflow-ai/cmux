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

extension TabBarBackground {
    /// Whether the strip paints its own fill: always when darker; for
    /// window only where the window sheet behind it shows another color
    /// (a workspace theme of the other lightness than its room), so the
    /// negative space is always the pane's window color.
    public func paintsStripFill(paneWindowBackground: ThemeRGB, sheet: ThemeRGB) -> Bool {
        self == .darker || paneWindowBackground != sheet
    }
}
