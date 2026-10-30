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
        // Read when a card draws and again at a press: a menu left open while the setting turns off
        // keeps its cards.
        let pictureInPicture: () -> Bool = { [weak services] in PictureInPictureHandlers.isEnabled(services) }
        let shown = sessions.map { _ in ShownRow() }
        let cards = zip(sessions, shown).map { session, row in
            card(session.entry.tab, session.media, pictureInPicture: pictureInPicture, row: row, registry: services.registry)
        }
        let menu = rows.menu(cards, empty: BrowserHitStrings.mediaNothingPlaying)
        for ((view, session), row) in zip(zip(menu.items.compactMap { $0.view as? BrowserMediaRowView }, sessions), shown) {
            row.view = view
            loadArtwork(view, tab: session.entry.tab, url: session.media.artworkURL)
        }
        return menu
    }

    /// `pictureInPicture` reads `media.pictureInPicture.enabled`; off, the card has no Picture in
    /// Picture button, and a button still on screen after it turns off does nothing.
    /// `row`: the card's view once the menu holds it, so a press refused after it drew can be undone.
    private static func card(_ tab: any BrowserTab, _ media: BrowserMediaState, pictureInPicture: @escaping () -> Bool,
                             row: ShownRow, registry: ActionRegistry) -> BrowserMediaRows.Card {
        let site = tab.state.url?.host() ?? ""
        let title = media.title.isEmpty ? (tab.state.title ?? site) : media.title
        let subtitle = [media.artist, site].filter { !$0.isEmpty }.joined(separator: " · ")
        let target = ActionTargetRef(kind: .tab, id: tab.id.rawValue)
        return BrowserMediaRows.Card(
            key: tab.id.rawValue, title: title, subtitle: subtitle, media: media, artwork: tab.favicon, pictureInPicture: pictureInPicture,
            onCommand: { [weak tab] command in
                guard let tab, command != .pictureInPicture || pictureInPicture() else { return }
                // A muted tab's media stays muted until the tab unmutes.
                if command == .toggleMute, tab.state.isAudioMuted, let muting = tab as? any BrowserAudioMuting {
                    return muting.setAudioMuted(false)
                }
                Task {
                    // Turned off between the press and this task: nothing floats, and the card shows
                    // the page's real state again instead of the Exit it showed.
                    if command == .pictureInPicture, !pictureInPicture() {
                        return row.view?.showPictureInPicture(tab.state.media?.isPictureInPicture == true)
                    }
                    await tab.media(command)
                }
            },
            onReveal: { [weak registry] in
                registry?.perform("tab.focus", invocation: ActionInvocation(target: target, origin: .user))
            })
    }

    /// A card's view, filled in once the menu holds it.
    final class ShownRow {
        weak var view: BrowserMediaRowView?
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
