public import AppKit

/// The top row's horizontal rhythm: the traffic lights, the toolbar band (sidebar toggle, Back,
/// Forward) and the sidebar's +, with one rule set at every density (Lucas 2026-11-10: "make sure
/// that they are all relatively proportional in terms of positioning and spacing throughout all the
/// different modes").
///
/// - The lights sit as far from the window's left edge as from its top (``TrafficLightsLine``).
/// - The toggle's glyph sits one glyph gap right of the lights (``leadingGap``).
/// - Every top-row button is one size, the sidebar's +'s (``buttonSide``), and the chrome's other buttons take it too
///   (`TitlebarBandButton.side`).
/// - As in cmux classic (Lawrence 2026-11-11: "make it look like that"), the toggle, Back and Forward stand one
///   ``groupGap`` apart, and the lights stand that far plus a glyph's margin before the toggle, so the glyphs and the
///   lights sit evenly at every density (the gaps were uneven at Compact).
public struct TopRowSpacing {
    public init() {}

    /// Every top-row button's side: the band's toggle, Back and Forward, and the sidebar's +.
    public static var buttonSide: CGFloat { Metrics.sidebarHeaderHeight }

    /// The gap between two top-row buttons (the toggle and Back, Back and Forward): classic's 6 pt between its
    /// 20 pt buttons, three tenths of a button on the half-point grid.
    public static var groupGap: CGFloat { (buttonSide * 0.3 * 2).rounded() / 2 }

    /// The top row's one glyph height (Lucas 2026-11-11: the toggle, the arrows and the + were three sizes, "make
    /// them proportional/same size, especially the arrows"): the +'s extent, so every glyph's ink is this tall.
    public static var glyphExtent: CGFloat { Metrics.addGlyphExtent }
    /// The box Chrome's arrows draw in: their ink is 0.6 of it (design/icons/chromium manifest, 14.4 of the 24 grid).
    public static var arrowIconSize: CGFloat { (glyphExtent / 0.6 * 2).rounded() / 2 }
    /// The panel toggle's point size: its ink stands about 0.95 of it tall (SidebarToggleGlyph).
    public static var toggleGlyphPointSize: CGFloat { (glyphExtent / 0.95 * 2).rounded() / 2 }
    /// The toggle's ink width: its canvas (1.38 of the point size) less the outline's insets.
    static var toggleInkWidth: CGFloat { toggleGlyphPointSize * 1.235 }
    /// The gap after the toggle's button: ``groupGap`` plus the room the wider toggle glyph takes from the arrows'
    /// ink width, so the toggle's glyph and Back's stand as far apart as Back's and Forward's.
    public static var toggleGap: CGFloat { groupGap + max(0, toggleInkWidth - glyphExtent) / 2 }

    /// The band's full width: the toggle, ``toggleGap``, Back, ``groupGap``, Forward.
    public static var bandWidth: CGFloat { buttonSide * 3 + toggleGap + groupGap }

    /// The gap from the lights' trailing edge to the toggle's button, so the lights stand as far from the toggle's
    /// glyph as Back's glyph from Forward's (``groupGap`` and two arrow margins), less the toggle's own margin.
    /// Never under `space1`, so the button stays clear of the lights.
    public static var leadingGap: CGFloat {
        let between = groupGap + max(0, buttonSide - glyphExtent)
        return max(Metrics.space1, between - max(0, buttonSide - toggleInkWidth) / 2)
    }
}
