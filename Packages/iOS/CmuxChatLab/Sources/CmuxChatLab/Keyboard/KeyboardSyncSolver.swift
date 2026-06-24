import CoreGraphics

/// Pure geometry for keeping an inverted message list glued to a composer that
/// rides the keyboard. Kept free of UIKit so it unit-tests on the host.
///
/// The whole subsystem derives from one scalar per frame: the composer's top
/// edge in the list view's own coordinate space. From it we compute the list's
/// visual-bottom inset and, when the user is scrolled away from the bottom, the
/// content-offset compensation that keeps the visible content stationary while
/// the inset changes. This is the UIKit expression of Telegram's "one scalar,
/// one pass" discipline: the composer position and the list inset can never
/// disagree because they are computed from the same number.
public enum KeyboardSyncSolver {
    /// The list's bottom overlap: how far the composer (and, when raised, the
    /// keyboard it rides) intrudes into the list from its bottom edge.
    ///
    /// On an inverted collection view this is applied as `contentInset.top`
    /// (the inverted list's visual bottom). Item 0 then rests just above the
    /// composer.
    ///
    /// - Parameters:
    ///   - listMaxY: The list view's bottom edge in its own space (`bounds.maxY`).
    ///   - composerTopInList: The composer's top edge converted into the list's space.
    /// - Returns: A non-negative overlap.
    public static func bottomOverlap(listMaxY: CGFloat, composerTopInList: CGFloat) -> CGFloat {
        max(0, listMaxY - composerTopInList)
    }

    /// The content-offset delta to apply when the inset changes so already-
    /// visible content does not shift under the user.
    ///
    /// Only applied when the user is not pinned to the bottom; at the bottom we
    /// want the newest message to stay visible and ride up with the keyboard,
    /// so the caller skips compensation there.
    public static func offsetCompensation(previousInset: CGFloat, newInset: CGFloat) -> CGFloat {
        newInset - previousInset
    }

    /// Whether the inverted list is effectively pinned to the visual bottom
    /// (newest message showing), within a tolerance.
    ///
    /// On an inverted list the visual bottom is the minimum content offset,
    /// which equals `-contentInset.top`.
    public static func isPinnedToBottom(
        contentOffsetY: CGFloat,
        topInset: CGFloat,
        tolerance: CGFloat = 1
    ) -> Bool {
        contentOffsetY <= (-topInset) + tolerance
    }
}
