public import CmuxNextDaemon
public import Foundation

/// A chat share link the app was handed (a click on a share page, or the guest page's open-in-app
/// `<scheme>://share?link=...#<secret>`), opened as a guest browser tab: the daemon checks the link and,
/// with the person's cmux token, gets the room's one-time hand-off, so the tab joins as the person's own
/// account (`agent-session-share-open-link`, cmux-tui `agent_session_share_link.rs`). The secret stays in the
/// page URL's fragment. A web address the daemon refuses still opens as itself; an app link it refuses
/// opens nothing.
@MainActor
public struct AgentShareLinks {
    public let host: any AgentShareHost

    public init(host: any AgentShareHost) { self.host = host }

    /// Asks the daemon for `link`'s page, then hands it to `openTab`.
    public func open(_ link: URL, openTab: @escaping @MainActor (URL) -> Void) {
        // A web address the daemon refuses (another site's `/g/<id>`, or no daemon) opens exactly as given.
        let fallback = link.scheme?.lowercased() == "https" ? link : nil
        // task-owner: AgentShareLinks.open: one daemon request, then one tab; ends with it.
        Task { [self] in
            guard let page = await page(link) ?? fallback else { return }
            openTab(page)
        }
    }

    /// `link`'s page as the daemon answers it, once this Mac's daemon is connected (a cold launch from a link waits
    /// for it); nil when the daemon refuses or startup gave up.
    public func page(_ link: URL) async -> URL? {
        let opener = await host.shareLinkOpener()
        guard let connection = opener.connection else { return nil }
        let request = AgentSessionShareOpenLinkRequest(link: link.absoluteString, token: opener.token)
        // timeout: a room that never answers the hand-off (the daemon gives it 10 s); past this the link
        // still opens as itself, signed out (the fallback in `open`).
        guard let opened = try? await connection.request(request, timeout: .seconds(20)) else { return nil }
        return URL(string: opened.url)
    }
}
