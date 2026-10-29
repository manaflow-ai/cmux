import CmuxNextSignposts
import Foundation
import os

/// What a ``PageWebView`` does when its renderer dies (p13-webui.md 3.C): a shown page reloads at once,
/// a hidden one is marked to load when it shows, and none reloads once its budget ran out. Chrome does
/// the same for a background tab: `NavigationControllerImpl::SetNeedsReload` marks it, any navigation
/// clears the mark, and `LoadIfNecessary` reloads it once `WebContentsImpl::WasShown` makes the
/// controller active (content/browser/renderer_host/navigation_controller_impl.cc), so a renderer that
/// held one shown page and four hidden ones costs one load, not five.
///
/// A page waits for its show only in ``groups`` (the ``WebUIHost`` sets it while the page lifecycle,
/// the one visibility source, is on); otherwise it keeps its own budget and reloads at once, hidden or
/// not. A page shares its group's budget only when its host shows the crash notice (``PageWebView/onCrash``):
/// another page's crash loop may stop it, and only that notice's Reload brings it back.
@MainActor
package final class PageCrashRecovery {
    /// The crash budgets of the page's host; nil: the page's own budget.
    var groups: PageCrashGroups?
    /// The page's WebKit view joined the host's shared WebContent processes (``WebProcessGroups``).
    var sharesWebKitProcess = false
    /// Where the page's WebKit content-process ends go as stability events; its host sets the
    /// app's one (``WebUIHost/rendererStability``), nil records none.
    var stability: RendererStability?
    private var own = PageCrashReloads()
    /// Its renderer died while it was hidden: it loads when it shows.
    package private(set) var needsReload = false
    /// What a load asked for while the page waited for its show (``mayLoad(_:)``): the show loads it
    /// instead of reloading the old document.
    private var waitingURL: URL?
    /// How many times the page was loaded again after a crash (tests, the crash bench).
    package private(set) var reloads = 0
    /// What the page's engine was last told (``PageWebView/setEngineVisible(_:)``, from its view's
    /// window and hidden state): whether a person can see the page.
    private var shown = false
    /// The renderer the page's document committed in; nil once it died, until the next commit.
    private var renderer: PageRendererID?
    /// The WebContent process the page's WebKit document last committed in, the one its content end names to
    /// ``stability``; nil before then and once it ended.
    private var webKitProcess: Int32?

    package init() {}

    /// `page`'s renderer died (``PageWebView/contentProcessTerminated()``): its document's state is reset,
    /// and it reloads now, waits for its show, or stops; its host hears it (``PageWebView/onCrash``).
    func crashed(_ page: PageWebView) {
        page.loaded = false
        page.router.reset()
        let now = page.now(), died = renderer
        renderer = nil
        let reloading = groups.map { $0.recordCrash(key(page), renderer: died, at: now) } ?? own.shouldReload(at: now)
        needsReload = reloading && groups != nil && !shown
        if reloading, !needsReload {
            reload(page)
        } else {
            page.loadState.set(loading: false, page: page) // no load follows now
            if !reloading { Self.logStop(page) }
        }
        page.onCrash?(page, reloading)
    }

    /// The page's WebKit document committed in `process` (``PageWebView/webView(_:didCommit:)``).
    func webKitCommitted(in process: Int32?) {
        webKitProcess = process
        if let process { stability?.webKitContentCommitted(in: process) }
    }

    /// The page's WebKit content process ended: one `page` stability event that names the process, so the other
    /// grouped pages it served (``WebProcessGroups``) add no process end.
    func webKitContentEnded() {
        stability?.webKitContentEnded(on: .page, process: webKitProcess)
        webKitProcess = nil
    }

    /// `page` committed a document (``PageWebView/documentCommitted()``): its renderer is read, the one
    /// whose death a later crash reports.
    func committed(_ page: PageWebView) {
        guard let groups else { return }
        renderer = groups.rendererID(page)
        if let renderer { groups.rendererCommitted(renderer, in: key(page)) }
    }

    /// Whether `page` may start a load now (``PageWebView/loadDocument(_:)`` with `url`,
    /// ``PageWebView/reloadPage()`` with nil). False while it waits for its show: the show makes the one
    /// load, of the last `url` asked for, so a hidden page loads nothing until a person can see it.
    func mayLoad(_ url: URL?) -> Bool {
        guard needsReload else { return true }
        if let url { waitingURL = url }
        return false
    }

    /// `page`'s engine is told it shows or hides (``PageWebView/setEngineVisible(_:)``). A page whose
    /// renderer died while it was hidden loads as it shows, unless its group crashed past its budget
    /// since; then its host hears that it stopped, and shows the crash notice.
    func engineVisibilityChanged(_ visible: Bool, page: PageWebView) {
        shown = visible
        guard visible, needsReload else { return }
        needsReload = false
        let url = waitingURL
        waitingURL = nil
        guard groups?.allowsReload(key(page), at: page.now()) ?? true else {
            Self.logStop(page)
            page.onCrash?(page, false)
            return
        }
        page.loadState.set(loading: true, page: page)
        reloads += 1
        page.logger.error("page \(page.descriptor.id, privacy: .public) web content ended while hidden; reloading automatically as it shows cause=renderer-exit")
        if let url { page.loadDocument(url) } else { page.reloadPage() }
    }

    /// The person reloads `page` from its crash notice: the crashes counted against it, and against
    /// its group, are forgotten, and it reloads.
    func reloadAfterCrashes(_ page: PageWebView) {
        own = PageCrashReloads()
        needsReload = false
        waitingURL = nil
        groups?.forgive(key(page))
        page.reloadPage()
    }

    /// Whose budget `page`'s crash counts against: its group's only when the page really shares a
    /// renderer in the engine that shows it now and its host can bring it back (``PageWebView/onCrash``).
    private func key(_ page: PageWebView) -> PageCrashGroups.Key {
        let engine: PageCrashGroups.Engine = page.chromiumSession != nil ? .chromium : .webKit
        let shares: Bool = switch engine {
        case .webKit: sharesWebKitProcess
        case .chromium: groups?.chromiumSharesByGroup == true && page.descriptor.processGroup.sharesRenderer
        }
        return shares && page.onCrash != nil ? .group(engine, page.descriptor.processGroup) : .page(ObjectIdentifier(page))
    }

    private func reload(_ page: PageWebView) {
        reloads += 1
        // Every automatic reload is in the field log (cmux#25920); a host that shows the crash notice gets none.
        page.logger.error("page \(page.descriptor.id, privacy: .public) web content ended; reloading automatically cause=renderer-exit")
        page.reloadPage()
    }

    private static func logStop(_ page: PageWebView) {
        page.logger.error("page \(page.descriptor.id, privacy: .public) keeps crashing; not reloaded")
    }
}
