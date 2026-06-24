import CoreGraphics

/// Resolves the width to size chat bubbles against from the container widths
/// available at cell-configuration time.
///
/// The bubble cap is `width * theme.bubbleMaxWidthFraction`, and a
/// non-positive width resolves the `\.chatBubbleMaxWidth` environment to
/// `.infinity`, leaving the bubble uncapped.
///
/// On the first layout pass of a freshly-inserted pending row (the "on send"
/// case) the transcript table's own `bounds.width` is not resolved yet (0), so
/// the bubble measures uncapped: it renders full-width, then snaps to the cap
/// once `bounds.width` resolves on the next pass. Falling back to the hosting
/// window (then its screen) width yields a correct provisional cap on the
/// first render and removes the wide-then-narrow snap.
enum ChatContainerWidthResolver {
    /// First positive width among the table bounds, hosting window, and its
    /// screen; `0` only when none is known yet (caller then treats the cap as
    /// `.infinity`).
    static func effectiveWidth(
        boundsWidth: CGFloat,
        windowWidth: CGFloat?,
        screenWidth: CGFloat?
    ) -> CGFloat {
        if boundsWidth > 0 { return boundsWidth }
        return 0
    }
}
