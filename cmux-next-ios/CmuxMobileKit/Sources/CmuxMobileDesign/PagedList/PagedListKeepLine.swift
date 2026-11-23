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

    /// The reader's top edge, except while the list's own slide to its newest row runs (following,
    /// no finger, no fling): then the bottom edge. A row on screen that changes height mid-slide (an
    /// arrival measuring from its estimate, an edit) moves the offset with it, so the rows under it
    /// stay where they are drawn and the slide's position moves by the same amount
    /// (``PagedListScrollSpring`` carries any outside move of the offset): what is drawn changes
    /// only by the slide's step. In both directions: an `.up` list keeps its newest row on the bottom
    /// edge as older rows grow (Messages), a `.down` list keeps what is read still while the rows
    /// arriving at its top size themselves on the way in. At rest the layout pass keeps the newest row
    /// (`stayOnNewest`), and a list read mid-list keeps the reader's row, as before.
    static func line(_ state: State) -> CGFloat {
        state.follows && state.sliding && !state.scrolling ? state.bottomEdge : state.readerTop
    }
}
#endif
