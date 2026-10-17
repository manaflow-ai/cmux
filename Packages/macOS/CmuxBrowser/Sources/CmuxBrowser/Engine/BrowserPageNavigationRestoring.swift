/// A page that can take back/forward history it exported earlier
/// (``BrowserPage/exportRestoreState()``) after it was created, so a
/// reopened tab gets its history back instead of loading its address fresh.
@MainActor
public protocol BrowserPageNavigationRestoring: AnyObject {
    /// Restores `state` in place of the page's next load.
    /// - Returns: `false` when the engine cannot read `state`; the caller
    ///   then loads the address instead.
    @discardableResult
    func restoreNavigation(_ state: BrowserPageRestoreState) -> Bool
}
