import AppKit
import CmuxNextActions
import CmuxNextBrowser

/// The toolbar's media hub (`browser.media.show`, Edge's Now Playing,
/// cx-6qwm.2): one card per tab with media, playing first
/// (`BrowserMediaRowView`). A card's controls run in that tab's page
/// (`BrowserTab.media`); a click on the card goes to the tab (`tab.focus`).
/// The artwork loads through the tab's own context (`fetchFavicon`), the
/// tab's favicon meanwhile.
enum BrowserMediaMenu {
    /// The hub's menu; `rows` keeps each tab's card between opens.
    static func menu(_ services: AppServices, rows: BrowserMediaRows) -> NSMenu {
        let sessions = services.cache.pageRequests.media.sessions(in: services.cache)
        let cards = sessions.map { card($0.entry.tab, $0.media, registry: services.registry) }
        let menu = rows.menu(cards, empty: BrowserHitStrings.mediaNothingPlaying)
        for (view, session) in zip(menu.items.compactMap { $0.view as? BrowserMediaRowView }, sessions) {
            loadArtwork(view, tab: session.entry.tab, url: session.media.artworkURL)
        }
        return menu
    }

    private static func card(_ tab: any BrowserTab, _ media: BrowserMediaState, registry: ActionRegistry) -> BrowserMediaRows.Card {
        let site = tab.state.url?.host() ?? ""
        let title = media.title.isEmpty ? (tab.state.title ?? site) : media.title
        let subtitle = [media.artist, site].filter { !$0.isEmpty }.joined(separator: " · ")
        let target = ActionTargetRef(kind: .tab, id: tab.id.rawValue)
        return BrowserMediaRows.Card(
            key: tab.id.rawValue, title: title, subtitle: subtitle, media: media, artwork: tab.favicon,
            onCommand: { [weak tab] command in
                guard let tab else { return }
                // A muted tab's media stays muted until the tab unmutes.
                if command == .toggleMute, tab.state.isAudioMuted, let muting = tab as? any BrowserAudioMuting {
                    return muting.setAudioMuted(false)
                }
                Task { await tab.media(command) }
            },
            onReveal: { [weak registry] in
                registry?.perform("tab.focus", invocation: ActionInvocation(target: target, origin: .user))
            })
    }

    /// Loads the artwork through the tab's own context (`fetchFavicon`) once per address.
    private static func loadArtwork(_ row: BrowserMediaRowView, tab: any BrowserTab, url: URL?) {
        guard let url, row.artworkURL != url else { return }
        Task { [weak row, weak tab] in
            guard let image = await tab?.fetchFavicon(url) else { return }
            row?.setArtwork(image)
            row?.artworkURL = url
        }
    }
}
