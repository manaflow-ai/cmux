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
    static func menu(_ services: AppServices) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let sessions = services.cache.pageRequests.media.sessions(in: services.cache)
        if sessions.isEmpty {
            let empty = NSMenuItem(title: BrowserHitStrings.mediaNothingPlaying, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (index, session) in sessions.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let item = NSMenuItem()
            item.view = row(session.entry.tab, session.media, registry: services.registry)
            menu.addItem(item)
        }
        return menu
    }

    private static func row(_ tab: any BrowserTab, _ media: BrowserMediaState, registry: ActionRegistry) -> BrowserMediaRowView {
        let site = tab.state.url?.host() ?? ""
        let title = media.title.isEmpty ? (tab.state.title ?? site) : media.title
        let subtitle = [media.artist, site].filter { !$0.isEmpty }.joined(separator: " · ")
        let target = ActionTargetRef(kind: .tab, id: tab.id.rawValue)
        let row = BrowserMediaRowView(
            title: title, subtitle: subtitle, media: media, artwork: tab.favicon,
            onCommand: { [weak tab] command in
                guard let tab else { return }
                Task { await tab.media(command) }
            },
            onReveal: { [weak registry] in
                registry?.perform("tab.focus", invocation: ActionInvocation(target: target, origin: .user))
            })
        if let url = media.artworkURL {
            Task { [weak row, weak tab] in
                guard let image = await tab?.fetchFavicon(url) else { return }
                row?.setArtwork(image)
            }
        }
        return row
    }
}
