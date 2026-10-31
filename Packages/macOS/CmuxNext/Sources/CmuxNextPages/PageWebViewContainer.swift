public import AppKit

/// A view that shows one of several views and names the page view it shows now: the docked Home, whose
/// Channels view is a page. The app's focus model finds the page a tab shows through it
/// (``PageWebView/shown(in:)``), so a page in Chromium inside such a view gets the keyboard like a
/// page tab's own page.
@MainActor
public protocol PageWebViewContainer: AnyObject {
    /// The page view shown now; nil when the shown view is not a page.
    var shownPageView: PageWebView? { get }
}

extension PageWebView {
    /// The page view `content` shows now: `content` itself, or the shown page of a container
    /// (``PageWebViewContainer``); nil for any other view.
    ///
    /// - Parameter content: A tab's content view (an internal page's provider view).
    /// - Returns: The page view that shows there now.
    public static func shown(in content: NSView) -> PageWebView? {
        content as? PageWebView ?? (content as? any PageWebViewContainer)?.shownPageView
    }
}
