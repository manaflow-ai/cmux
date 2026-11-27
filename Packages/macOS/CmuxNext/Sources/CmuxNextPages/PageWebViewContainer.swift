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

extension PageWebView {
    /// Lifts `content` one point above `host`'s top while the page it shows draws in Chromium, so
    /// `host` clips Chrome's frame line away. A Chrome-style page window lays its web contents one point
    /// under its top edge and draws its frame there: on a page whose top is its host's top edge
    /// (Settings, the Markdown page with its bar below) it doubled the window's top line (Lucas
    /// 2026-11-12: "the top border looks thicker than the others"), as on New Tab before #40286. Only
    /// the active constraint from `content`'s top to `host`'s top moves; a page under a bar keeps its
    /// place. The page asks its host, its superview, for this layout when Chromium starts or stops
    /// showing it (``chromiumSession``), so only a page that is the content itself lifts: a container's
    /// page (the docked Home) would never ask, and its native views would stay lifted.
    ///
    /// - Parameters:
    ///   - content: The host's page content.
    ///   - host: The view that holds `content`; the pane around it clips the lifted point.
    public static func clipChromiumFrame(of content: NSView, in host: NSView) {
        let lift: CGFloat = (content as? PageWebView)?.showsChromium == true ? chromiumFrameBand : 0
        for top in host.constraints where top.firstItem === content && top.firstAttribute == .top
            && top.secondItem === host && top.secondAttribute == .top && top.constant != -lift {
            top.constant = -lift
        }
    }

    /// The points of a Chrome-style page window above its web contents.
    public static let chromiumFrameBand: CGFloat = 1
}
