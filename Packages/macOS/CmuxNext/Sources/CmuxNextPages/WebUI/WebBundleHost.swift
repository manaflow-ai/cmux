public import Foundation

/// A cmux page a change of the served web files reaches: a web UI update at its safe point, or a
/// `web-dev.json` change (p13-webui.md 3.C, task 071). ``PageWebView`` is one; tests pass fakes.
@MainActor
package protocol WebBundlePage: AnyObject, Sendable {
    /// The page shows a running document now: its engine was told it shows, and it is neither
    /// discarded, waiting for its first show nor the pool's parked spare.
    var bundleShown: Bool { get }
    /// The page holds a document that loaded files (shown, hidden, frozen or parked; not discarded
    /// and not waiting for its first show): a change reloads it or marks it stale.
    var bundleHasDocument: Bool { get }
    /// The page is the pool's parked spare: nobody sees it, and its claim loads the files served then
    /// when it is stale (``markBundleStale()``), so the swap never reloads it.
    var bundleParked: Bool { get }
    /// The page is loading a document now (it is busy for the safe point).
    var bundleLoading: Bool { get }
    /// What the page shows now, so a look notices a page that navigated while it answered.
    var bundleDocument: URL? { get }
    /// The page keeps a document of web files a change replaced (``markBundleStale()``) and has not
    /// reloaded since.
    var bundleStale: Bool { get }
    /// Asks the page, in its own world, whether a reload keeps what it holds
    /// (`window.cmuxWebSwap.hold()`, webviews/src/pages/shared/webSwap.ts): nil when it does, else why not.
    func askBundleSwap() async -> String?
    /// Loads the same document again; the scheme handler answers it from the files served now.
    func reloadForBundle()
    /// The page keeps its old document while hidden, frozen or parked. Its claim loads the new files;
    /// its show hands it to the safe point (``WebBundleSafePoint``), which reloads it only when it
    /// answers that a reload keeps what it holds.
    func markBundleStale()
}

/// Reloads a page that shows with web files it has not loaded (``WebBundlePage/bundleStale``) at a
/// safe point: it asks the page as it shows, reloads it when a reload keeps all it holds
/// (`window.cmuxWebSwap.hold()` answers null), else keeps its document, which its pinned tree still
/// serves (``WebBundleOverlay/Pin``), and asks again under the swap's rules (the app's web updates,
/// plans/cmux-next/web-ota.md). Chrome reloads a tab marked `SetNeedsReload` as it is shown
/// (content/browser/renderer_host/navigation_controller_impl.cc, `LoadIfNecessary`), but that tab's
/// document is already gone; a cmux page kept its document and can still lose what it holds.
@MainActor
package protocol WebBundleSafePoint: AnyObject {
    /// `page` shows now with web files it has not loaded.
    func staleShown(_ page: any WebBundlePage)
}

/// The pages a web files change reaches, and how the change reaches them: the swap goes through
/// the page host, never a list of every web view ever served (p13-webui.md 3.C, task 071).
///
/// With ``bundleReloadsOnShow`` (feature `webUpdateReloadOnShow`), after Chrome's model: a background
/// tab that must load again is marked by `NavigationControllerImpl::SetNeedsReload` and loads once
/// `WebContentsImpl::WasShown` makes it active (content/browser/renderer_host/navigation_controller_impl.cc),
/// so only what a person sees pays a load now, and a frozen page is never woken to answer. A cmux page
/// keeps its document meanwhile, so its show asks it first (``WebBundleSafePoint``). Without it, every
/// page that holds a document is asked and reloads at the swap, as before.
@MainActor
package protocol WebBundleHost: AnyObject {
    /// Every page the host holds that is served from the web update folder, shown or not.
    var webBundlePages: [any WebBundlePage] { get }
    /// Hidden and frozen pages wait for their show (feature `webUpdateReloadOnShow`).
    var bundleReloadsOnShow: Bool { get }
    /// The served files changed: the pages ``bundleAskedPages`` lists reload now, and every other page
    /// that holds a document is marked stale; its claim loads the new files, and its show hands it to
    /// the safe point (``WebBundleSafePoint``).
    ///
    /// - Returns: How many pages reloaded now.
    @discardableResult func webBundleDidChange() -> Int
}

extension WebBundleHost {
    /// The pages the swap reloads now, which the safe point asks: the shown ones with
    /// ``bundleReloadsOnShow``, else every page that holds a document. Never the parked spare.
    package var bundleAskedPages: [any WebBundlePage] { webBundlePages.filter { reloadsAtSwap($0) } }

    /// The pages that show with web files they have not loaded: the safe point asks them and reloads
    /// them once they allow it (``WebBundleSafePoint``).
    package var staleShownPages: [any WebBundlePage] { webBundlePages.filter { $0.bundleStale && $0.bundleShown } }

    /// Whether the swap reloads `page` now (``bundleAskedPages``).
    package func reloadsAtSwap(_ page: any WebBundlePage) -> Bool {
        guard page.bundleHasDocument, !page.bundleParked else { return false }
        return page.bundleShown || !bundleReloadsOnShow
    }

    /// Reloads the pages of `pages` the swap reloads now and marks the others that hold a document
    /// stale, in one turn. A page marked here is never called into.
    ///
    /// - Returns: How many pages reloaded now.
    package func reloadOrMarkStale(_ pages: [any WebBundlePage]) -> Int {
        var reloaded = 0
        for page in pages where page.bundleHasDocument {
            if reloadsAtSwap(page) {
                page.reloadForBundle()
                reloaded += 1
            } else {
                page.markBundleStale()
            }
        }
        return reloaded
    }
}
