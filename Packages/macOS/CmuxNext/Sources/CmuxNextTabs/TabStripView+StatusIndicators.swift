public import CmuxNextDesign

/// The strip is its busy tabs' indicator host in the window: one placement per strip, not one per
/// tab, so a Cmd-Tab or window switch reaches the shown strips of the window that changed, and a
/// parked workspace's strip in the same window costs nothing until it shows.
extension TabStripView: StatusIndicatorResyncClient {
    public func statusIndicatorResync() {
        for cell in cells.values where cell.showsStatusIndicator { cell.statusIndicatorResync() }
    }
}
