/// How many times a strip walked its whole row, by pass (``TabStripView``'s `rowPasses`). A tab switch
/// between tabs that already show changes two cells and their lines: it walks no row, so its cost does
/// not grow with the tab count (tab-switch-rewrite). Tests read the counts around a change.
struct TabStripRowPasses: Equatable {
    /// `updateOcclusion` passes (the selected pill's masks over every cell).
    var occlusion = 0
    /// Full separator passes (`TabSeparatorVisibility.apply(to:)`).
    var separators = 0
    /// `applyFrames` passes (every cell placed: a relayout).
    var frames = 0
    /// Tabs whose occlusion mask was cut again, over every pass (a full pass counts every tab).
    var occlusionTabs = 0
    /// Wheel scrolls (`scrollChanged`): the scrolling layer's bounds, the + and the fades; no cell is placed.
    var scrolls = 0
    /// Cell frames (or opacities) a frame pass wrote: only the tabs whose place changed.
    var cellFrames = 0
    /// Full syncs (`sync(fromModel:)`: every tab's item and cell, then a relayout). A content-only model change
    /// (a title, a spinner) and an echo run none.
    var syncs = 0
}
