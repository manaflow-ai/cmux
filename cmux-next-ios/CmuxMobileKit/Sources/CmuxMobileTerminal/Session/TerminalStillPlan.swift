import CoreGraphics

/// What a still of the terminal page holds (the grid card's snapshot and the
/// frame saved for the next cold launch): the terminal's rows on its
/// background, nothing else. qa11 grid-composer-in-card: composing the
/// page's chrome layers (composer, key bar, status bar band) drew the
/// composer across a card's middle over rows. The rows shown are the ones a
/// person reads on the page: below the top inset, above the composer card.
struct TerminalStillPlan {
    /// Chrome layers are never part of a still.
    static let drawsChromeLayers = false

    /// The page's rows area in the page's points.
    static func rowsClip(bounds: CGRect, topInset: CGFloat, composerTop: CGFloat) -> CGRect {
        let top = min(max(bounds.minY, bounds.minY + topInset), bounds.maxY)
        let bottom = min(max(top, composerTop), bounds.maxY)
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: bottom - top)
    }

    /// Where a still's rows are read from on the page and where they are
    /// drawn in the still. A still is always composed as the page looks with
    /// the keyboard down and the composer at rest. While the keyboard is up
    /// (or the composer has grown), the stack's top sits `shift` points above
    /// its resting top, and the rows ride up with it. Clipping at that raised
    /// top left the band down to the bottom edge as bare background, the
    /// keyboard's gap. The kept frame carried that band into the grid card
    /// (bottom-aligned, `TerminalCardCrop`) and the next cold launch. Leo,
    /// 2026-11-25: "the served cached thing included the gap induced by my
    /// built-in keyboard". The rows are drawn `shift` points lower, so they end
    /// at the resting top. `source` is the drawn area moved up by `shift`.
    struct Placement: Equatable {
        /// The rows area in the still (page points): from the top inset down to the resting stack top.
        var clip: CGRect
        /// How far the rows are drawn below where they sit on the page now.
        var shift: CGFloat
        /// The page area the rows are read from.
        var source: CGRect { clip.offsetBy(dx: 0, dy: -shift) }
    }

    static func placement(bounds: CGRect, topInset: CGFloat, composerTop: CGFloat, restingComposerTop: CGFloat) -> Placement {
        // Within a point of rest is rest: no shift for rounding between the two measures.
        let shift = restingComposerTop - composerTop > 1 ? restingComposerTop - composerTop : 0
        return Placement(clip: rowsClip(bounds: bounds, topInset: topInset, composerTop: composerTop + shift), shift: shift)
    }
}
