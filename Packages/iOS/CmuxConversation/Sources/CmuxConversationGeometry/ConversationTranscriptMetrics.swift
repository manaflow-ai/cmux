import CoreGraphics

/// Transcript sizing rules read from ChatKit on iOS 26.5 and 27.0 (iPhone 17
/// Pro and Pro Max simulators, Large text), shared by every surface that
/// lays out bubbles.
public enum ConversationTranscriptMetrics {
    /// What ChatKit keeps free beside the widest balloon: `CKUIBehavior
    /// balloonMaxWidthForTranscriptWidth:` takes the transcript width less the
    /// entry view's content insets (the margins plus 107.33 pt), less the
    /// balloon's 5 pt line fragment insets, plus its 14 pt pill insets. That
    /// is the width between the margins less 89.33 pt: 280.67 on a 402 pt
    /// phone (370 between 16 pt margins), 310.67 on 440 (400 between 20 pt).
    public static let balloonWidthReserve: CGFloat = 268.0 / 3.0

    /// ChatKit's ceiling on that: 85% of the width between the margins
    /// (`balloonMaxWidthPercent`); it only binds above 595 pt.
    public static let balloonMaxWidthFraction: CGFloat = 0.85

    /// Widest balloon (tail area included, which is none on iOS 26 and 27)
    /// for `width` of transcript between the side margins, at the default
    /// and larger non-accessibility text sizes.
    public static func balloonMaxWidth(betweenMargins width: CGFloat) -> CGFloat {
        max(0, min(width - balloonWidthReserve, width * balloonMaxWidthFraction))
    }

    /// ChatKit sizes a balloon to its text and rounds the result up to the
    /// pixel grid: "Are we still on for dinner tonight?" is 249.70 pt of text
    /// in a 278.00 pt balloon (249.70 + 28 = 277.70, up to 278.00 at @3x), one
    /// 20.29 pt line in a 40.33 pt balloon.
    public static func ceilToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let s = scale > 0 ? scale : 1
        // A hair of tolerance so an exact pixel value (278.0000001) stays put.
        return ((value * s) - 0.001).rounded(.up) / s
    }
}
