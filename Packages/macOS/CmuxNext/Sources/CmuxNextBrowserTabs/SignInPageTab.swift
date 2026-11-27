public import Foundation

/// Which tab a sign-in's end closes (Cancel, finished or expired; `LinkOpener.openSignInPage`), so the
/// provider's page it opened does not stay behind. Leo 2026-11-23: "WE ABSOLUELY MUST ERR ON THE SIDE
/// OF BEING NOT ANNOYING", which cuts both ways: no leftover page, and never a tab that may not be
/// this sign-in's.
public nonisolated struct SignInPageTab {
    public nonisolated init() {}
    /// Of the browser tabs made since the sign-in opened its page (`made`: each tab's id and the
    /// addresses it shows, the live page's first, then the daemon's record), the one to close: the
    /// only one still on the host of `url`, or on one of `hosts`. A tab the person took to another site
    /// stays, and with two on those hosts (another sign-in of that provider still running) neither closes.
    /// `hosts` are the sign-in's own as acpmux names them (the start's `pageHosts`,
    /// `agent_login::parse::page_hosts`): a provider whose page moves between its own hosts while the
    /// person signs in (Claude: claude.com, then claude.ai) still closes.
    public static func toClose<ID>(_ made: [(id: ID, shown: [URL?])], of url: URL, hosts: [String] = []) -> ID? {
        let pages = made.filter { onHost($0.shown, of: url, hosts: hosts) }
        return pages.count == 1 ? pages[0].id : nil
    }

    /// Whether a tab still shows the sign-in's provider: its first web address (a load error's own
    /// page is none) is on `url`'s host or one of `hosts`.
    public static func onHost(_ shown: [URL?], of url: URL, hosts: [String] = []) -> Bool {
        guard let host = url.host?.lowercased(),
              let page = shown.compactMap({ $0 }).first(where: { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }) else { return false }
        guard let shownHost = page.host?.lowercased() else { return false }
        return shownHost == host || hosts.contains { $0.lowercased() == shownHost }
    }
}
