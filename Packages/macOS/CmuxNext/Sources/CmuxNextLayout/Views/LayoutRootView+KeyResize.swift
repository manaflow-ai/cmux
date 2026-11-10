import AppKit

/// The keyboard resize seam (`PaneResize.press`, `resizePane*`): what a press may change on a screen, and what the
/// screen does for it.
extension LayoutRootView {
    /// The split ratios and column widths `pane`'s screen can show (``ShownResizeRange``), from the geometry its springs
    /// head for and where its strip camera rests; nil for a screen not sized yet. A keyboard resize steps inside them
    /// (RESIZE KEYS K1).
    public func shownResizeRange(ofScreenContaining pane: PaneID) -> ShownResizeRange? {
        guard let screen = model.screen(containing: pane), let view = screenViews[screen.id], view.bounds.width > 0 else { return nil }
        return ShownResizeRange(geometry: view.baseGeometry, style: context.style, scale: view.reconciledScale ?? view.scale,
                                stripOffset: view.scroll.target)
    }

    /// A keyboard resize press (`resizePane*`) is about to move `pane`'s screen: until that spring lands, every pane of
    /// the screen keeps its content at its size and lays it out once at the landing (RESIZE KEYS K3). `keeping`: the
    /// strip column whose place the press's layout keeps (the left one of two columns that trade width): the camera
    /// does not move for that layout, so only the divider between them moves (FRAME OWNER REFACTOR KEYS).
    public func keyboardResizeWillChange(screenContaining pane: PaneID, keeping column: ColumnID? = nil) {
        guard let screen = model.screen(containing: pane), let view = screenViews[screen.id], !view.isHidden else { return }
        view.holdsContentForKeyResize = true
        view.scrollState.keptColumn = column
    }

    /// The press's own sync ran, or had nothing to show (its values were refused while they went out): the column it
    /// kept in place applies to no later sync, and with nothing moving its content hold ends too (a later structural
    /// change must not start held).
    public func keyboardResizeDidChange(screenContaining pane: PaneID) {
        guard let screen = model.screen(containing: pane), let view = screenViews[screen.id] else { return }
        view.scrollState.keptColumn = nil
        if !view.hasMotion { view.holdsContentForKeyResize = false }
    }
}
