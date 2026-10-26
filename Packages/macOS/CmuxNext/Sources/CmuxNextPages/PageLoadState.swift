/// A ``PageWebView``'s document load as the page lifecycle reads it: loading from the load's start until
/// it finished or failed, as Chrome's `PageNode::IsLoading` (its kLoading freeze blocker). Unlike a first
/// paint, which a hidden page never makes, the load also ends while the page is hidden; each change tells
/// the lifecycle that holds the page, so a page that hid while loading freezes once its load ends.
@MainActor
final class PageLoadState {
    /// The current document loads.
    private(set) var isLoading = true
    /// The page lifecycle that holds the page (``PageLifecycleTarget/reportsReasonChanges(to:)``).
    weak var lifecycle: PageLifecycle?

    /// `page`'s load started (`true`), or finished or failed (`false`).
    func set(loading: Bool, page: AnyObject) {
        guard loading != isLoading else { return }
        isLoading = loading
        lifecycle?.pageReasonsDidChange(page)
    }

    /// Sets the state with no call to the lifecycle: the lifecycle's own step changed it (a discard
    /// ends the document, and a pass needs no second look at a page it just discarded).
    func set(loading: Bool) { isLoading = loading }
}
