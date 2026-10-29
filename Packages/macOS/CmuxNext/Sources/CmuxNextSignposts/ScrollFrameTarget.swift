/// Who took a timed scroll event (``ScrollFrameTiming``, the end's `target=` of
/// ``SignpostName/scrollToFrame``).
public nonisolated enum ScrollFrameTarget: String, Sendable, Hashable {
    /// The layout scrolled the columns strip, a column's rows, a scroll area or a canvas: the commit
    /// that ends the turn shows the move.
    case layout
    /// The event went on to the view under the pointer (a terminal's scrollback, a page): that view
    /// may show it in a later frame.
    case content
}
