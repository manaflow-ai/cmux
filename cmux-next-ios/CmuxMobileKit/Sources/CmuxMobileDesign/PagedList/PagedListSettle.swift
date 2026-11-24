#if os(iOS)
import CoreGraphics

/// Whether an update settles the rows' self-sizing and restores the reader once more before it ends
/// (``PagedListController``'s update): one extra pass at most, so it cannot loop.
enum PagedListSettle {
    struct State {
        /// An `.up` list (newest row at the bottom).
        var up: Bool
        /// The list follows its newest row and its own slide runs or starts with this update.
        var sliding: Bool
        /// A finger is on the list, or a fling still moves it.
        var scrolling: Bool
        /// The update kept the reader with an anchor (rows came, went or changed).
        var anchored: Bool
        /// How far the kept row is now from where the anchor held it, after the rows on screen
        /// sized themselves (pt): what the restore would correct again.
        var drift: CGFloat
    }

    /// Only an `.up` list sliding to its newest row, with no finger and no fling, after an anchored
    /// update whose kept row drifted more than half a point once its rows sized themselves. A `.down`
    /// list's rows above the reader are the rows arriving at its top (restoring again corrects their
    /// move twice); at rest the layout pass keeps the newest row; under a scroll the scroll moves them.
    static func again(_ state: State) -> Bool {
        state.up && state.sliding && !state.scrolling && state.anchored && abs(state.drift) > 0.5
    }
}
#endif
