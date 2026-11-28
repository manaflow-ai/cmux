public import CoreGraphics

/// Where a single-line title fades and how far its hover marquee scrolls.
/// Pure, so the rules are unit-tested without layers. All lengths are in the
/// title's own coordinates: 0 is where its first glyph rests.
///
/// A clipped title fades out instead of ending in an ellipsis (Chromium's
/// `FADE_TAIL`). The fade ends where the title must be clear
/// (`visibleWidth`, plus the padding after it) and is `fadeWidth` long. The
/// marquee moves the title left until its last glyph sits where the fade
/// starts, so the end reads fully opaque; the glyphs that leave on the left
/// fade out across `leadingPadding` (the row's own padding, left of the
/// first glyph), and over at least `fadeWidth` while it scrolls (``scrolledMaskLocations``). Both fades are alpha
/// masks, so they work on every theme.
public nonisolated struct TitleFadeGeometry: Equatable, Sendable {
    /// Typographic width of the whole title.
    public var textWidth: CGFloat
    /// Width of the title's layer at rest: the farthest it may ever draw.
    public var span: CGFloat
    /// Where the title must be clear at rest (for example before a tab's x).
    /// At most `span`.
    public var visibleWidth: CGFloat
    /// Padding before the first glyph that the marquee fades across.
    public var leadingPadding: CGFloat
    /// Padding after `visibleWidth` that the trailing fade may reach into.
    public var trailingPadding: CGFloat
    /// Longest trailing fade.
    public var fadeWidth: CGFloat
    /// Width of the title layer while it is at rest. This can be narrower than
    /// ``span`` when the rendered title must share its span with a trailing
    /// close button or badge. Marquee mode expands back to the full span.
    public var restWidth: CGFloat
    /// Where each word after a space starts, in the title's coordinates (``WordStart``). Empty: the fade ends
    /// where the title must be clear, whatever glyph that cuts.
    public var wordStarts: [WordStart]

    /// A word that follows a space: where its first glyph starts and ends.
    public struct WordStart: Equatable, Sendable {
        public var x: CGFloat
        public var firstGlyphEnd: CGFloat

        public init(x: CGFloat, firstGlyphEnd: CGFloat) {
            self.x = x
            self.firstGlyphEnd = firstGlyphEnd
        }
    }

    public init(textWidth: CGFloat, span: CGFloat, visibleWidth: CGFloat, leadingPadding: CGFloat,
                trailingPadding: CGFloat, fadeWidth: CGFloat, restWidth: CGFloat? = nil, wordStarts: [WordStart] = []) {
        self.textWidth = max(0, textWidth)
        self.span = max(0, span)
        self.visibleWidth = max(0, min(visibleWidth, span))
        self.leadingPadding = max(0, leadingPadding)
        self.trailingPadding = max(0, trailingPadding)
        self.fadeWidth = max(0, fadeWidth)
        self.restWidth = max(0, min(self.span, restWidth ?? self.span))
        self.wordStarts = wordStarts
    }

    /// The title does not fit before `visibleWidth`.
    public var isTruncated: Bool { span > 0 && textWidth > visibleWidth + 0.5 }

    /// Where the title must be clear: the trailing fade ends here or before.
    public var clearEdge: CGFloat { min(span, visibleWidth + trailingPadding) }

    /// Where the trailing fade reaches clear: ``clearEdge``, or the start of the word whose first glyph that edge
    /// cuts. A fade that ends inside a word's first glyph leaves a faint fragment of it after the space, a mark
    /// that reads as no letter: a crowded "New Tab" read "New" and a tick at cap height, the left end of the T's
    /// crossbar (Leo 2026-11-23, "the end bit the text has a weird rewritten thing"). The fade ends at the space
    /// instead, so the title ends on the last word it shows. A first word too long to fit keeps the glyph fade.
    public var fadeEnd: CGFloat {
        let edge = clearEdge
        guard isTruncated, let word = Self.cutWord(wordStarts, at: edge) else { return edge }
        return word.x
    }

    /// The word after a space whose first glyph `edge` cuts (some of it shows, not all of it).
    static func cutWord(_ words: [WordStart], at edge: CGFloat) -> WordStart? {
        words.first { $0.x > 0.5 && $0.x < edge - 0.01 && edge < $0.firstGlyphEnd - 0.01 }
    }

    /// Where the trailing fade starts (fully opaque before it).
    public var fadeStart: CGFloat {
        let length = min(fadeWidth, max(fadeEnd, 1) * 0.5)
        return max(0, fadeEnd - length)
    }

    /// How far the marquee scrolls: the last glyph ends where the fade starts.
    public var marqueeTravel: CGFloat {
        guard isTruncated else { return 0 }
        return max(0, textWidth - fadeStart).rounded(.up)
    }

    /// Frame of the fade mask in the title's coordinates: from the leading
    /// padding to the end of the rest span.
    public var maskFrame: (x: CGFloat, width: CGFloat) {
        (-leadingPadding, leadingPadding + span)
    }

    /// Gradient stops across `maskFrame` for colors clear, opaque, opaque,
    /// clear, clear.
    public var maskLocations: [CGFloat] {
        let width = max(1, leadingPadding + span)
        return [0, leadingPadding / width, (leadingPadding + fadeStart) / width, (leadingPadding + fadeEnd) / width, 1]
    }

    /// Gradient stops while the marquee has scrolled the title: as ``maskLocations``, but the glyphs that leave on the
    /// left fade out over at least `fadeWidth`, reaching into the title where ``leadingPadding`` is shorter. A
    /// text-only sidebar row has no padding before its first glyph, so with the rest stops its marquee cut the leaving
    /// glyphs with a hard edge and left a sliced stub at the row's edge (Lawrence 2026-11-09, "left side transparency
    /// is bad"). The ramp never reaches past half the opaque run before ``fadeStart``.
    public var scrolledMaskLocations: [CGFloat] {
        let width = max(1, leadingPadding + span)
        let ramp = min(max(leadingPadding, fadeWidth), leadingPadding + fadeStart * 0.5)
        return [0, max(leadingPadding, ramp) / width, (leadingPadding + fadeStart) / width, (leadingPadding + fadeEnd) / width, 1]
    }

    /// Width the title's layer needs: its span, or the whole title while
    /// the marquee may show its end.
    public func layerWidth(marquee: Bool) -> CGFloat {
        marquee && isTruncated ? max(span, ceil(textWidth)) : restWidth
    }
}
