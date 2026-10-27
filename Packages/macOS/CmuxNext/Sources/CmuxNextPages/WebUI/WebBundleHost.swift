public import Foundation

/// A cmux page a change of the served web files reaches: a web UI update at its safe point, or a
/// `web-dev.json` change (p13-webui.md 3.C, task 071). ``PageWebView`` is one; tests pass fakes.
@MainActor
package protocol WebBundlePage: AnyObject, Sendable {
    /// The page shows a running document now: its engine was told it shows, and it is neither
    /// discarded nor waiting for its first show. Only these pages are asked and reloaded.
    var bundleShown: Bool { get }
    /// The page holds a document that loaded files (shown, hidden or frozen; not discarded, not
    /// waiting for its first show and not the pool's parked spare): a change marks it stale.
    var bundleHasDocument: Bool { get }
    /// The page is loading a document now (it is busy for the safe point).
    var bundleLoading: Bool { get }
    /// What the page shows now, so a look notices a page that navigated while it answered.
    var bundleDocument: URL? { get }
    /// Asks the shown page, in its own world, whether a reload keeps what it holds
    /// (`window.cmuxWebSwap.hold()`, webviews/src/pages/shared/webSwap.ts): nil when it does, else why not.
    func askBundleSwap() async -> String?
    /// Loads the same document again; the scheme handler answers it from the files served now.
    func reloadForBundle()
    /// The page keeps its old document while hidden or frozen and reloads as it shows.
    func markBundleStale()
}

/// The pages a web files change reaches, and how the change reaches them: the swap goes through
/// the page host, never a list of every web view ever served (p13-webui.md 3.C, task 071).
///
/// Chrome does the same for a renderer it must load again: `NavigationControllerImpl::SetNeedsReload`
/// marks a background tab and `LoadIfNecessary` reloads it once `WebContentsImpl::WasShown` makes it
/// active (content/browser/renderer_host/navigation_controller_impl.cc), so only what a person sees
/// pays a load now, and a frozen page is never woken to answer.
@MainActor
package protocol WebBundleHost: AnyObject {
    /// Every page the host holds now, shown or not.
    var webBundlePages: [any WebBundlePage] { get }
    /// The served files changed: shown pages reload now, every other page that holds a document is
    /// marked stale and reloads when it shows, and a preloaded page is dropped and made again.
    ///
    /// - Returns: How many pages reloaded now.
    @discardableResult func webBundleDidChange() -> Int
}

extension WebBundleHost {
    /// The pages the safe point asks: those shown now (``WebBundlePage/bundleShown``).
    package var shownBundlePages: [any WebBundlePage] { webBundlePages.filter(\.bundleShown) }

    /// Reloads the shown pages of `pages` and marks the others that hold a document stale, in one
    /// turn. A hidden or frozen page is never called into here.
    ///
    /// - Returns: How many pages reloaded now.
    package func reloadShownMarkingOthers(_ pages: [any WebBundlePage]) -> Int {
        var reloaded = 0
        for page in pages {
            if page.bundleShown {
                page.reloadForBundle()
                reloaded += 1
            } else if page.bundleHasDocument {
                page.markBundleStale()
            }
        }
        return reloaded
    }
}
