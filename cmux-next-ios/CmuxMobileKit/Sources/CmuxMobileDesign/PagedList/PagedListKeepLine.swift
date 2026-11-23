#if os(iOS)
import CoreGraphics

/// The line, in content coordinates, above which a row that changes height moves the offset with
/// it, so the rows under that row stay where they are drawn (``PagedListLayout``'s correction and
/// the measure's account of it).
enum PagedListKeepLine {
    struct State {
        /// The list follows its newest row (an `.up` list at its bottom, a `.down` one at its top).
        var follows: Bool
        /// The list's own slide to its newest row is running (``PagedListScrollSpring``).
        var sliding: Bool
        /// A finger is on the list, or a fling still moves it.
        var scrolling: Bool
        /// The reader's top edge and the list's bottom edge, in content coordinates.
        var readerTop: CGFloat
        var bottomEdge: CGFloat
    }

    static func line(_ state: State) -> CGFloat {
        state.readerTop
    }
}
#endif
