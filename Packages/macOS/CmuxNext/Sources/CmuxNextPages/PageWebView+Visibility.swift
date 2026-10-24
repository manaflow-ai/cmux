import AppKit

/// Whether anybody can see the page, for its router (``PageRouter/isPageHidden``): a page out of a
/// window or hidden (another tab took the pane, a hidden workspace) gets no subscription events
/// until it shows, and then gets them in one script. Each event to a hidden page was a main-thread
/// script evaluation and a render in its web process (#8900). Either engine: the router feeds
/// WebKit and Chromium pages alike.
///
/// A page in a covered or minimized window still gets its events: following each window's
/// occlusion needs one registration per window shared by its pages (arch-ratchet observer_sites),
/// not one per page, so it is a separate change (open in perf-lead.md row 23).
@MainActor
extension PageWebView {
    /// Tells the router whether nobody can see the page now (never, for a page that does not hold
    /// its events, ``holdsEventsWhileHidden``). Showing it sends the waiting events. AppKit tells the
    /// view each change of the rule's inputs (`viewDidMoveToWindow`, `viewDidHide`, `viewDidUnhide`).
    func updatePageVisibility() {
        let hidden = holdsEventsWhileHidden && Self.nobodySees(self)
        if router.isPageHidden != hidden { router.isPageHidden = hidden }
    }

    /// Whether nobody can see `view`: out of a window, or it or an ancestor hidden.
    static func nobodySees(_ view: NSView) -> Bool {
        view.window == nil || view.isHiddenOrHasHiddenAncestor
    }
}
