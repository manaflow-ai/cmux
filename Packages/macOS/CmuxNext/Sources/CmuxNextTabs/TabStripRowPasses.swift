/// How many times a strip walked its whole row, by pass (``TabStripView``'s `rowPasses`). A tab switch
/// between tabs that already show changes two cells and their lines: it walks no row, so its cost does
/// not grow with the tab count (tab-switch-rewrite). Tests read the counts around a change.
struct TabStripRowPasses: Equatable {
    /// `updateOcclusion` passes (the selected pill's masks over every cell).
    var occlusion = 0
    /// Full separator passes (`TabSeparatorVisibility.apply(to:)`).
    var separators = 0
    /// `applyFrames` passes (every cell placed: a relayout, a scroll).
    var frames = 0
}
