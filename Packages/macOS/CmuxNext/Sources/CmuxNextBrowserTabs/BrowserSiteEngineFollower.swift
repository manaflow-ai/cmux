public import CmuxNextBrowser
public import CmuxNextSettings
public import Foundation

/// Follows the pages Chromium tabs commit and moves a tab to WebKit when its page's
/// `browser.siteEngines` rule says so (``BrowserSiteEngineNavigation``,
/// https://github.com/manaflow-ai/cmux/issues/45018). The host supplies the rules, what it knows
/// of a page's tab, and the reopen; this owns the per-page memory (the last committed page, a
/// typed address, a kept `window.opener`).
///
/// A check runs on its own turn after the commit, never inside the observed read that reported it,
/// and once per committed address. A page whose tab is not a pane's tab yet (a stand-in waiting for
/// the daemon) is checked again when ``follow(_:page:)`` mounts it under its tab.
@MainActor
public final class BrowserSiteEngineFollower {
    /// What the host knows of a page's tab, nil when the page is no pane's tab (yet).
    public struct Tab: Sendable {
        public var enginePinned: Bool
        public var alreadyReopened: Bool
        /// Its pane shows it now: the WebKit tab then takes its place in front, else it opens behind.
        public var shown: Bool

        public init(enginePinned: Bool, alreadyReopened: Bool, shown: Bool) {
            self.enginePinned = enginePinned
            self.alreadyReopened = alreadyReopened
            self.shown = shown
        }
    }

    private final class Memory {
        var last: URL?
        var typed = false
        var keepsOpener = false
        /// A move that waited for the page's tab (a stand-in).
        var pending: URL?
    }

    private let rules: @MainActor () -> BrowserSiteEngines
    private let tab: @MainActor (any BrowserTab) -> Tab?
    private let reopen: @MainActor (any BrowserTab, URL, _ background: Bool) -> Void
    private let memories = NSMapTable<AnyObject, Memory>.weakToStrongObjects()

    /// - Parameters:
    ///   - rules: The live `browser.siteEngines`.
    ///   - tab: The page's tab, nil while it has none.
    ///   - reopen: Opens the address in a WebKit tab after the page's tab (behind it when
    ///     `background`) and closes the Chromium tab.
    public init(rules: @escaping @MainActor () -> BrowserSiteEngines, tab: @escaping @MainActor (any BrowserTab) -> Tab?,
                reopen: @escaping @MainActor (any BrowserTab, URL, _ background: Bool) -> Void) {
        self.rules = rules
        self.tab = tab
        self.reopen = reopen
    }

    /// Follows `page` (a Chromium page) through `state`, its tab's chrome state; call it again when the
    /// page moves to another tab. The page's current page, or a move that waited for a tab, is checked now.
    public func follow(_ state: BrowserChromeTabState, page: any BrowserTab) {
        guard page.engineKind == .cef else { return }
        state.onPageCommitted = { [weak self, weak page] url in
            guard let self, let page else { return }
            committed(url, page: page)
        }
        let known = remembered(page)
        if let pending = known.pending {
            check(pending, page: page, fresh: true)
        } else if known.last == nil, page.state.phase == .committed || page.state.phase == .finished, let url = page.state.url {
            committed(url, page: page)
        }
    }

    /// The person committed an address in `page`'s omnibar: the page it commits next arrived fresh.
    public func typedCommit(_ page: any BrowserTab) { remembered(page).typed = true }

    /// `page` was made by its opener's engine and keeps `window.opener`: it never moves.
    public func keepsOpener(_ page: any BrowserTab) { remembered(page).keepsOpener = true }

    private func committed(_ url: URL, page: any BrowserTab) {
        let known = remembered(page)
        guard url != known.last else { return }
        let previous = known.last
        known.last = url
        let fresh = known.typed || !Self.isWeb(previous)
        known.typed = false
        check(url, page: page, fresh: fresh)
    }

    private func check(_ url: URL, page: any BrowserTab, fresh: Bool) {
        // task-owner: one check after the observed read that reported the commit (a reopen makes tabs).
        Task { [weak self, weak page] in
            guard let self, let page else { return }
            let known = remembered(page)
            known.pending = nil
            var move = BrowserSiteEngineNavigation(siteEngine: rules().engine(for: url), engineIsChromium: page.engineKind == .cef,
                                                   arrivedFresh: fresh, keepsOpener: known.keepsOpener, enginePinned: false,
                                                   alreadyReopened: false, agentDriven: page.isAgentDriven)
            guard move.reopensInWebKit, page.state.url == url else { return }
            guard let found = tab(page) else { known.pending = url; return }
            (move.enginePinned, move.alreadyReopened) = (found.enginePinned, found.alreadyReopened)
            if move.reopensInWebKit { reopen(page, url, !found.shown) }
        }
    }

    private func remembered(_ page: any BrowserTab) -> Memory {
        if let known = memories.object(forKey: page as AnyObject) { return known }
        let made = Memory()
        memories.setObject(made, forKey: page as AnyObject)
        return made
    }

    private static func isWeb(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
