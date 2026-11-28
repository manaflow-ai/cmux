/// `appearance.toolbarButtonStyle`: how the buttons at a pane's top right (its pinned tab bar buttons and Exit Zoom)
/// and the tab bar's + and ⌄ draw. A theme file sets it like any `appearance.*` key, and a change applies at
/// once (`PaneToolbarView`, `TabStripView`).
///
/// Leo 2026-11-18: "you guys should be customizing the tabs/sidebars a lot deeper too. prob likewise the session
/// info and the top right buttons as well".
public nonisolated enum ToolbarButtonStyle: String, Sendable, CaseIterable, Hashable {
    /// Today's look, unchanged (the default): the tab bar's buttons follow `TabTunables.trailingButtons`.
    case standard
    /// Bare glyphs: no fill at rest, the glyph brightens under the pointer.
    case plain
    /// One filled pill holds the pane's buttons; the glyphs inside it take no fill of their own.
    case grouped
    /// The pill in see-through glass with a hairline rim.
    case glass

    /// Whether the pane's buttons sit on one shared pill (``grouped`` and ``glass``).
    public var drawsGroup: Bool { self == .grouped || self == .glass }

    /// The hover style the buttons take, or nil to keep the tab bar's own (`TabTunables.trailingButtons`). Inside a
    /// pill a second fill per button would stack on the pill, so they brighten their glyph only.
    public var hoverStyle: ChromeHoverStyle? { self == .standard ? nil : .glyph }
}
