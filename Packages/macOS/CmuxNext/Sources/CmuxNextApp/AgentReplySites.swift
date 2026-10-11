import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextSettings

/// The App's side of an agent pane's reply links (D4, D6): the settings, and the favicon and
/// title of a linked page from what cmux already holds. A favicon comes only from an open browser
/// tab of the same site whose icon the favicon loader has cached for that tab's profile; nothing
/// is fetched, and a tab of an incognito workspace is never read.
@MainActor
struct AgentReplySites {
    let services: AppServices

    func wire(_ links: AgentPaneReplyLinks) {
        links.settings = { [weak services] in services?.settings?.snapshot.agentPaneReplies ?? .fallback }
        links.sites = { [weak services] urls in
            guard let services else { return [:] }
            return AgentReplySites(services: services).sites(for: urls)
        }
    }

    func sites(for urls: [URL]) -> [URL: AgentPaneReplySite] {
        var tabs: [(url: URL, icon: URL?, title: String, key: String)] = []
        for workspace in services.daemon.store.workspaces where !workspace.ephemeral {
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
                guard let address = tab.url, let url = URL(string: address) else { continue }
                tabs.append((url, tab.faviconURL.flatMap(URL.init(string:)), tab.title, tab.id))
            }
        }
        var out: [URL: AgentPaneReplySite] = [:]
        for url in urls {
            var site = AgentPaneReplySite()
            for tab in tabs where Self.sameSite(tab.url, url) {
                if site.title == nil, Self.samePage(tab.url, url), !tab.title.isEmpty { site.title = tab.title }
                if site.iconPNG == nil, let icon = tab.icon {
                    let profile = services.browserProfiles.engineProfile(forTab: tab.key)
                    site.iconPNG = BrowserFaviconLoader.shared.cachedFavicon(at: icon, profile: profile).flatMap(Self.png)
                }
            }
            if site.iconPNG != nil || site.title != nil { out[url] = site }
        }
        return out
    }

    static func sameSite(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host(percentEncoded: false)?.lowercased() == b.host(percentEncoded: false)?.lowercased()
            && a.port == b.port
    }

    static func samePage(_ a: URL, _ b: URL) -> Bool {
        sameSite(a, b) && a.path(percentEncoded: true) == b.path(percentEncoded: true) && a.query == b.query
    }

    static func png(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
