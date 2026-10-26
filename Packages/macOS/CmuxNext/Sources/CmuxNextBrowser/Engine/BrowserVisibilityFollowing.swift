public import CmuxNextWakeups

/// A capture of a page that cmux shows nowhere (an agent's screenshot or screencast, the phone's browser host,
/// screen share), as Chrome's `WebContents::IncrementCapturerCount(capture_size, stay_hidden, ...)`
/// (content/public/browser/web_contents.h). The raw values are the shim's `cmux_shim_tab_capture_t`.
public nonisolated enum BrowserPageCapture: Int32, Sendable {
    /// Nothing captures the page.
    case notCaptured = 0
    /// The page keeps painting and stays hidden to script: `stay_hidden`, Chrome's
    /// `PageVisibilityState::kHiddenButPainting`.
    case hiddenButPainting = 1
    /// The page paints and reads visible: a capture that does not stay hidden.
    case visible = 2

    /// The capture `node`'s votes ask for: ``VisibilityNode/isCaptured`` is a vote that does not stay hidden.
    @MainActor public static func votes(on node: VisibilityNode) -> BrowserPageCapture {
        node.isCaptured ? .visible : .notCaptured
    }
}

/// Tabs whose engine takes the page's visibility from the app's visibility tree (plans/cmux-next/chrome-parity/
/// p06-scheduler.md, section B): a hidden or occluded node hides or occludes the page to the engine in the node's
/// own turn, as Chrome's tab strip hides a background WebContents (`WebContentsImpl::UpdateWebContentsVisibility`).
/// WebKit follows its view's window itself.
public protocol BrowserVisibilityFollowing: AnyObject {
    /// Follows `node` from now until the page closes or follows another node; the tab holds `node`.
    ///
    /// - Parameters:
    ///   - node: The tab's node (`TabContentCache.node(for:)`).
    ///   - capture: The capture `node`'s votes ask for, read on each flip and capture change.
    /// - Returns: False when the engine has no such call: the page's own view decides, as before.
    @discardableResult
    func followVisibility(of node: VisibilityNode, capture: @escaping @MainActor (VisibilityNode) -> BrowserPageCapture) -> Bool
}
