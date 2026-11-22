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
/// first glyph). Both fades are alpha masks, so they work on every theme.
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

    public init(textWidth: CGFloat, span: CGFloat, visibleWidth: CGFloat, leadingPadding: CGFloat,
                trailingPadding: CGFloat, fadeWidth: CGFloat) {
        self.textWidth = max(0, textWidth)
        self.span = max(0, span)
        self.visibleWidth = max(0, min(visibleWidth, span))
        self.leadingPadding = max(0, leadingPadding)
        self.trailingPadding = max(0, trailingPadding)
        self.fadeWidth = max(0, fadeWidth)
    }

    /// The title does not fit before `visibleWidth`.
    public var isTruncated: Bool { span > 0 && textWidth > visibleWidth + 0.5 }

    /// Where the trailing fade reaches clear.
    public var fadeEnd: CGFloat { min(span, visibleWidth + trailingPadding) }

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

    /// Width the title's layer needs: its span, or the whole title while
    /// the marquee may show its end.
    public func layerWidth(marquee: Bool) -> CGFloat {
        marquee && isTruncated ? max(span, ceil(textWidth)) : span
    }
}
