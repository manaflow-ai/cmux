import Foundation

/// Which tab a sign-in's end closes (Cancel, finished or expired; `LinkOpener.openSignInPage`), so the
/// provider's page it opened does not stay behind. Leo 2026-11-23: "WE ABSOLUELY MUST ERR ON THE SIDE
/// OF BEING NOT ANNOYING", which cuts both ways: no leftover page, and never a tab that may not be
/// this sign-in's.
public nonisolated struct SignInPageTab {
    public nonisolated init() {}
    /// Of the browser tabs made since the sign-in opened its page (`made`: each tab's id and the
    /// addresses it shows, the live page's first, then the daemon's record), the one to close: the
    /// only one still on the host of `url`. A tab the person took to another site stays, and with
    /// two on that host (another sign-in of that provider still running) neither closes.
    public static func toClose<ID>(_ made: [(id: ID, shown: [URL?])], of url: URL) -> ID? {
        let pages = made.filter { onHost($0.shown, of: url) }
        return pages.count == 1 ? pages[0].id : nil
    }

    /// Whether a tab still shows the sign-in's provider: its first web address (a load error's own
    /// page is none) is on `url`'s host.
    public static func onHost(_ shown: [URL?], of url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              let page = shown.compactMap({ $0 }).first(where: { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }) else { return false }
        return page.host?.lowercased() == host
    }
}
