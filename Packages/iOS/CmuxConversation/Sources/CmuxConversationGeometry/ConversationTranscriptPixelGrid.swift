import CoreGraphics

/// Where transcript rows land on the pixel grid. Rows stack at their
/// unrounded heights and each top snaps to the grid, as ChatKit's transcript
/// does (40.287 pt bubbles 4 pt apart land at 232.33, 276.67, 321.00 in
/// Messages, iOS 26.5 and 27.0). Every top first takes a sub-pixel `phase`,
/// so rows that stay keep their pixel offsets from one another when rows
/// above them change (an older page landing, history trimmed): otherwise
/// the new rows' fractional height re-rounds every row below, and rows on
/// screen step a pixel against their neighbors.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationTranscriptPixelGrid {
    /// A raw top (stacked from the top padding) on the grid.
    public static func snap(_ rawTop: CGFloat, phase: CGFloat, scale: CGFloat) -> CGFloat {
        let s = max(1, scale)
        return ((rawTop + phase) * s).rounded() / s
    }

    /// The phase that keeps a row on the pixel offset it had: `rawTop` is
    /// the row's new raw top, `previousTop` its previous top before snapping
    /// (raw plus the previous phase). The result is within half a pixel.
    public static func phase(placing rawTop: CGFloat, likePreviousTop previousTop: CGFloat, scale: CGFloat) -> CGFloat {
        let pixel = 1 / max(1, scale)
        let shift = previousTop - rawTop
        // Any whole number of pixels can go; keep the remainder.
        return shift - (shift / pixel).rounded() * pixel
    }
}
