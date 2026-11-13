public import CmuxNextLayout

extension LayoutMapping.Result {
    /// The same layout with `pane` alone filling its screen, as a zoomed pane does; the screen's
    /// other panes are hidden, not closed.
    ///
    /// A fullscreen page's pane while its window gives the page the whole screen, as Chrome does
    /// with a page's fullscreen whatever else the window shows (`WindowController+FullScreen`).
    /// View-only: the daemon's tree, its zoom and every handle stay as they are, so leaving puts
    /// back exactly the layout the person had.
    ///
    /// - Parameter pane: The pane to show alone. A pane in no screen changes nothing.
    /// - Returns: The result with that pane's screen reduced to the one pane.
    public func presenting(_ pane: LayoutPaneID) -> Self {
        var result = self
        for index in result.screens.indices where result.screens[index].layout.contains(pane) {
            result.screens[index].layout = .splits(.leaf(pane))
            result.screens[index].zoomed = true
        }
        return result
    }
}
