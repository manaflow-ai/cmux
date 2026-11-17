public import AppKit

/// The top row's horizontal rhythm: the traffic lights, the toolbar band (sidebar toggle, Back,
/// Forward) and the sidebar's +, with one rule set at every density (Lucas 2026-11-10: "make sure
/// that they are all relatively proportional in terms of positioning and spacing throughout all the
/// different modes").
///
/// - The lights sit as far from the window's left edge as from its top (``TrafficLightsLine``).
/// - The toggle's glyph sits that same distance right of the lights (``leadingGap(lightsInset:glyphWidth:)``).
/// - Every top-row button is one size, the sidebar's +'s (``buttonSide``).
/// - Back and Forward touch, and ``groupGap`` sets the toggle and Back apart, so the three glyphs sit
///   evenly: the pair is never looser than the gap before it.
public struct TopRowSpacing {
    public init() {}

    /// Every top-row button's side: the band's toggle, Back and Forward, and the sidebar's +.
    public static var buttonSide: CGFloat { Metrics.sidebarHeaderHeight }

    /// The gap between the toggle's button and Back's, a third of a button on the half-point grid. Back
    /// and Forward have none: their narrow chevrons leave wide margins in their buttons, and the toggle's
    /// glyph almost fills its own, so this third evens the glyph gaps at every density.
    public static var groupGap: CGFloat { (buttonSide / 3 * 2).rounded() / 2 }

    /// The band's full width: the toggle, ``groupGap``, then Back and Forward.
    public static var bandWidth: CGFloat { buttonSide * 3 + groupGap }

    /// The gap from the lights' trailing edge to the toggle's button: the lights' inset from the
    /// window's edge less the glyph's own inset in its button, so the glyph sits `lightsInset` right
    /// of the lights. Never under `space1`, so the button stays clear of the lights.
    public static func leadingGap(lightsInset: CGFloat, glyphWidth: CGFloat) -> CGFloat {
        max(Metrics.space1, lightsInset - max(0, buttonSide - glyphWidth) / 2)
    }
}
