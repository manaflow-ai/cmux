#if DEBUG
extension CanvasRootView {
    /// Shows the Command+scroll discovery hint immediately for debug-menu and
    /// automation testing, replacing any visible hint and leaving the
    /// production one-time discovery flag unchanged.
    public func debugShowCommandScrollHint() {
        commandScrollHintTask?.cancel()
        presentCommandScrollHint(markSessionShown: false, replacingExisting: true)
    }
}
#endif
