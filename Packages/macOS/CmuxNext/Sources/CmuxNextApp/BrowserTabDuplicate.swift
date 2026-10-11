import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// Duplicate Tab on a browser tab (cx-d0d.56), as in Chrome: the copy
/// lands right after the original (the opener slot, so it also stays in
/// the original's tab group) and keeps its back/forward history, through
/// the state hibernation saves, in the same engine, profile and zoom. A
/// page that cannot save its history (another machine's tab, a Chromium
/// build without the restore API) opens its URL.
@MainActor
struct BrowserTabDuplicate {
    /// The original's pane, where the copy opens.
    let pane: PaneController

    func open(_ tab: TabModel) {
        let pane = pane, cache = pane.services.cache
        let page = cache.existingBrowser(tab.id)?.tab
        let url = page?.state.url ?? tab.url.flatMap(URL.init(string:))
        // The record names the original's profile, as the page's cookies do.
        let profile = pane.services.browserProfiles.profileID(ofTab: tab)
        guard let page, let state = Self.history(of: page) else {
            pane.newBrowserTab(url: url, inherited: tab.browserEngine, profile: profile, opener: tab.surface)
            return
        }
        var configuration = BrowserTabConfiguration(profile: page.profileID, initialURL: url, zoom: page.state.zoom)
        configuration.restoreState = state
        switch state {
        case .webKit:
            let copy = cache.webKit.makeWebKitTab(id: configuration.id, profile: configuration.profile, zoom: configuration.zoom)
            if !copy.restore(state), let url { copy.load(url) }
            pane.newBrowserTab(url: url, inherited: tab.browserEngine, adopting: copy, profile: profile, opener: tab.surface)
        case .chromium:
            pane.services.registry.track(Task { [weak pane] in
                // The remote-localhost store of the original, as for any Chromium page.
                let configured = await cache.chromiumConfiguration(for: tab, base: configuration)
                do {
                    let copy = try await cache.makeCEFTab(configured)
                    guard let pane else { copy.close(); return nil }
                    pane.newBrowserTab(url: url, inherited: tab.browserEngine, adopting: copy, profile: profile, opener: tab.surface)
                    return nil
                } catch {
                    // Chromium did not start: the URL alone, in the fallback engine.
                    pane?.newBrowserTab(url: url, inherited: tab.browserEngine, profile: profile, opener: tab.surface)
                    return nil
                }
            })
        }
    }

    /// The back/forward history `page` can be recreated from: a hibernated
    /// page's saved state, else what a live page saves now.
    static func history(of page: any BrowserTab) -> BrowserRestoreState? {
        if let hibernated = page as? HibernatedBrowserTab { return hibernated.restoreState }
        return (page as? any BrowserHibernationSource)?.hibernationState()
    }
}
