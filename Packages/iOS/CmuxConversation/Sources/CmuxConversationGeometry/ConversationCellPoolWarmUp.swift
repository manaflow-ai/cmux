import CoreGraphics

/// Spare cells for the transcript's reuse queues, made when a conversation
/// opens.
///
/// Opened at the newest message, every message cell UIKit has made is on
/// screen, so the reuse queues are empty. The first row that arrives then
/// builds a fresh `MessageCell` in the frame it animates in (12-17 ms on the
/// iOS 26.5 and 27.0 simulators). Laying the transcript out once at a
/// screenful of older rows and back, inside the open's own update (nothing
/// commits in between, so nothing shows), leaves those rows' cells queued,
/// one or more per reuse class the history uses.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationCellPoolWarmUp {
    /// How many viewports above the resting offset the spare cells come
    /// from: far enough that UIKit's prefetch window, which keeps cells for
    /// their own rows, does not hold them.
    public static let viewportsAbove: CGFloat = 2

    /// The content offset to lay out at, or nil when the loaded rows do not
    /// reach a screenful beyond what is on screen.
    public static func offset(restingY: CGFloat, topY: CGFloat, viewport: CGFloat) -> CGFloat? {
        guard viewport > 0 else { return nil }
        let y = max(topY, restingY - viewportsAbove * viewport)
        // A screenful there must not share rows with the one on screen.
        guard y + viewport <= restingY else { return nil }
        return y
    }
}
