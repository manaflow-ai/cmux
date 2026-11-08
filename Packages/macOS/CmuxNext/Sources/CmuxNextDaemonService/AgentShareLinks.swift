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
        let fallback = link.scheme?.lowercased() == "https" ? Self.inApp(link) : nil
        // task-owner: AgentShareLinks.open: one daemon request, then one tab; ends with it.
        Task { [self] in
            guard let page = await page(link) ?? fallback else { return }
            openTab(page)
        }
    }

    /// A page opened in cmux without the daemon's answer, marked as inside the app (`in_app=1`), so the guest
    /// page never asks the operating system to open it in cmux again.
    public static func inApp(_ page: URL) -> URL {
        guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return page }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "in_app" } + [URLQueryItem(name: "in_app", value: "1")]
        return parts.url ?? page
    }

    /// `link`'s page as the daemon answers it; nil when the daemon refuses or is not there.
    public func page(_ link: URL) async -> URL? {
        guard let connection = host.shareLocalConnection else { return nil }
        let request = AgentSessionShareOpenLinkRequest(link: link.absoluteString, token: await host.shareSignInToken())
        // timeout: a room that never answers the hand-off (the daemon gives it 10 s); past this the link
        // still opens as itself, signed out (the fallback in `open`).
        guard let opened = try? await connection.request(request, timeout: .seconds(20)) else { return nil }
        return URL(string: opened.url)
    }
}
