public import AppKit

/// The top row's horizontal rhythm: the traffic lights, the toolbar band (sidebar toggle, Back,
/// Forward) and the sidebar's +, with one rule set at every density (Lucas 2026-11-10: "make sure
/// that they are all relatively proportional in terms of positioning and spacing throughout all the
/// different modes"; Lawrence 2026-11-11, msg 29542: "spacing between traffic lights/sidebar and
/// back/forth needs to be perfectly even at all density sizes").
///
/// - The lights sit as far from the window's left edge as from its top (``TrafficLightsLine``).
/// - The lights, the toggle's glyph, Back's and Forward's stand one ``glyphGap`` apart, ink to ink, as in cmux
///   classic (Lawrence 2026-11-11: "make it look like that"), measured from each glyph's drawn ink
///   (``slots(side:gap:glyphs:)``), so the gaps stay even at every density and with any glyph.
/// - Every top-row button is the sidebar +'s height (``buttonSide``) and at most as wide, and the chrome's other
///   buttons take it too (`TitlebarBandButton.side`); a button whose narrow glyph sits closer than that to its
///   neighbor's is narrower, so the buttons tile the band with no overlap and no dead gap between them.
public struct TopRowSpacing {
    public init() {}

    /// Every top-row button's height and largest width: the band's toggle, Back and Forward, and the sidebar's +.
    public static var buttonSide: CGFloat { Metrics.sidebarHeaderHeight }

    /// Classic's 6 pt between its 20 pt buttons, three tenths of a button on the half-point grid.
    public static var groupGap: CGFloat { (buttonSide * 0.3 * 2).rounded() / 2 }

    /// The one ink gap between the lights and the toggle's glyph and between consecutive glyphs: classic's
    /// button gap plus two margins of an arrow (``glyphExtent``) in its button.
    public static var glyphGap: CGFloat { groupGap + max(0, buttonSide - glyphExtent) }

    /// The top row's one glyph height (Lucas 2026-11-11: the toggle, the arrows and the + were three sizes, "make
    /// them proportional/same size, especially the arrows"): the +'s extent, so every glyph's ink is this tall.
    public static var glyphExtent: CGFloat { Metrics.addGlyphExtent }
    /// The box Chrome's arrows draw in: their ink is 0.6 of it (design/icons/chromium manifest, 14.4 of the 24 grid).
    public static var arrowIconSize: CGFloat { (glyphExtent / 0.6 * 2).rounded() / 2 }
    /// The panel toggle's point size: its ink stands about 0.95 of it tall (SidebarToggleGlyph).
    public static var toggleGlyphPointSize: CGFloat { (glyphExtent / 0.95 * 2).rounded() / 2 }

    /// Where one glyph's ink sits in its image (``GlyphInkMeasure``).
    public struct Glyph: Equatable, Sendable {
        /// The image's width.
        public var imageWidth: CGFloat
        /// The ink's leading and trailing x in the image.
        public var ink: ClosedRange<CGFloat>

        /// - Parameter imageWidth: The image's width.
        /// - Parameter ink: The ink's horizontal extent in the image.
        public init(imageWidth: CGFloat, ink: ClosedRange<CGFloat>) {
            self.imageWidth = imageWidth
            self.ink = ink
        }

        /// The ink's width.
        var width: CGFloat { ink.upperBound - ink.lowerBound }
        /// The ink's center from the image's center (a button centers the image, not the ink).
        var centerOffset: CGFloat { (ink.lowerBound + ink.upperBound - imageWidth) / 2 }
    }

    /// The band's buttons at full width: each button's x and width (the first starts at 0), the
    /// band's full width, and the first glyph's leading ink inset from the band's origin.
    public struct Slots: Equatable, Sendable {
        /// Each button's leading x and width, in band order.
        public var frames: [(x: CGFloat, width: CGFloat)]
        /// The band's full width: its last button's trailing edge.
        public var width: CGFloat
        /// How far the first glyph's ink sits right of the band's origin.
        public var leadingInk: CGFloat

        public static func == (lhs: Slots, rhs: Slots) -> Bool {
            lhs.width == rhs.width && lhs.leadingInk == rhs.leadingInk
                && lhs.frames.map(\.x) == rhs.frames.map(\.x) && lhs.frames.map(\.width) == rhs.frames.map(\.width)
        }
    }

    /// Lays the band's buttons out so consecutive glyphs sit `gap` apart, ink to ink, each button
    /// centered on its image and at most `side` wide, bounded by the midpoints between its glyph and
    /// its neighbors'.
    /// - Parameter side: The buttons' largest width (``buttonSide``).
    /// - Parameter gap: The ink gap between consecutive glyphs (``glyphGap``).
    /// - Parameter glyphs: Each button's glyph, in band order.
    /// - Returns: The buttons' frames, the band's width and its first glyph's ink inset.
    public static func slots(side: CGFloat, gap: CGFloat, glyphs: [Glyph]) -> Slots {
        guard let first = glyphs.first else { return Slots(frames: [], width: 0, leadingInk: 0) }
        // Ink centers, from the first button's image center at side / 2.
        var centers = [side / 2 + first.centerOffset]
        for (previous, next) in zip(glyphs, glyphs.dropFirst()) {
            centers.append(centers[centers.count - 1] + previous.width / 2 + gap + next.width / 2)
        }
        // The tile edges between neighbors: halfway across each gap.
        let edges = zip(centers, glyphs).map { $0 + $1.width / 2 + gap / 2 }
        var frames: [(x: CGFloat, width: CGFloat)] = []
        for index in glyphs.indices {
            let middle = centers[index] - glyphs[index].centerOffset // the button centers its image here
            var half = side / 2
            if index > 0 { half = min(half, middle - edges[index - 1]) }
            if index < glyphs.count - 1 { half = min(half, edges[index] - middle) }
            half = max(0, half)
            frames.append((middle - half, half * 2))
        }
        let shift = frames[0].x // the band starts at its first button
        frames = frames.map { ($0.x - shift, $0.width) }
        let leadingInk = centers[0] - first.width / 2 - shift
        return Slots(frames: frames, width: (frames.last.map { $0.x + $0.width } ?? 0), leadingInk: leadingInk)
    }

    /// The gap from the lights' trailing edge to the band: `gap` less the toggle glyph's ink inset in
    /// the band, so the glyph sits `gap` right of the lights. Never under `space1`, so the button
    /// stays clear of the lights.
    /// - Parameter gap: The ink gap after the lights (``glyphGap``).
    /// - Parameter leadingInk: The toggle glyph's ink inset from the band's origin (``Slots/leadingInk``).
    public static func leadingGap(gap: CGFloat, leadingInk: CGFloat) -> CGFloat {
        max(Metrics.space1, gap - leadingInk)
    }
}
