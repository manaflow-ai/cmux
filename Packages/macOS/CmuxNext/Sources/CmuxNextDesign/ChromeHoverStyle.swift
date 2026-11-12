/// How an icon-only chrome button shows hover and press (the tab bar's +, its pane-type chevron and the pane's ⋮).
///
/// Lawrence 2026-11-07 ("i still dont like these UIs", a shot of the tab bar's `+ ⌄ ⋮` with a square grey block
/// behind the chevron): the three controls drew three different looks, a bare + beside two rounded plates. Every
/// style here is applied to all three at once, so they never disagree again.
public nonisolated enum ChromeHoverStyle: String, Sendable, CaseIterable, Hashable {
    /// A rounded-rectangle fill on the button's whole frame (``ChromeHover``'s look, before 2026-11-07).
    case plate
    /// No fill: the glyph brightens on hover and takes the lit ink while pressed or while its menu is open.
    case glyph
    /// A circle centered on the glyph, one diameter for every control.
    case circle

    /// Whether the style paints a fill behind the glyph.
    public var paintsFill: Bool { self != .glyph }
}
