import CmuxNextDesign
import WebKit

/// One WebKit web content process for the app's transparent overlay pages
/// (``PageWebKitReason/transparentOverlay``): dialogs, toasts, the icon picker, the group editor, the
/// sidebar's update islands and web cards.
///
/// These pages must be WebKit (Chromium's child window cannot be transparent over window glass). Each
/// page had its own `.nonPersistent()` data store, and WebKit starts a process per web view unless two
/// views share the pool and the data store and one is the other's related web view (`_relatedWebView`,
/// as ``WebProcessGroups`` does for agent pages). So a just-launched app that made four of them ahead of
/// their first open ran four WebContent processes, about 110 MB of footprint. Here every overlay page
/// shares one data store and joins the first live overlay page's process, up to ``pagesPerProcess``
/// pages, so they cost one process. None is made at launch: the icon picker and the group editor are
/// made on a sign someone may open one (a menu or palette open, a group header hover:
/// `MenuTracking.onMenus`) and freed after minutes unused, so an app idle at Home holds no overlay page. Each page keeps its own
/// origin (`cmux-page://<page id>/`), so their storage stays apart.
///
/// The composition root (`AppServices.overlayProcess`) makes the app's one instance and hands it to each
/// overlay page's owner, which passes it to ``PageWebView`` (`overlayProcess:`). A page made without one
/// keeps its own store and its own process: tests, every other page, and the browser chrome's popups
/// (`BrowserChromeWebHost`: Page Info's windows and the cookie import card, made only when opened).
@MainActor
public final class PageOverlayProcess {
    /// The most overlay pages one process serves: what one crash of that process takes down.
    let pagesPerProcess: Int
    /// The store every overlay page uses (a process is shared only within one store).
    let dataStore: WKWebsiteDataStore = .nonPersistent()
    /// The first page of the current group; its process serves the next pages.
    private weak var anchor: WKWebView?
    private var members = 0

    public init(pagesPerProcess: Int = 8) {
        self.pagesPerProcess = max(pagesPerProcess, 1)
    }

    /// Relates `configuration` to the current group's first page when it lives and has room, so the
    /// view made from it runs in that page's process; then call ``joined(_:)`` with the view.
    func prepare(_ configuration: WKWebViewConfiguration) {
        // A retired anchor whose page closed (WebViewRetirement) serves no new page, as in WebProcessGroups.
        guard let anchor, members < pagesPerProcess, WebViewRetirement.isPageClosed(anchor) != true,
              anchor.configuration.processPool === configuration.processPool,
              anchor.configuration.websiteDataStore === configuration.websiteDataStore else {
            members = 0
            return
        }
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_setRelatedWebView:")
        guard configuration.responds(to: selector) else {
            members = 0
            return
        }
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        configuration.perform(selector, with: anchor)
    }

    /// Records the view made after ``prepare(_:)``: it joined the group, or it starts a new one.
    func joined(_ view: WKWebView) {
        if members == 0 || anchor == nil {
            anchor = view
            members = 1
        } else {
            members += 1
        }
    }
}
