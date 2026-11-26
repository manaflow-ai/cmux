import Foundation

/// The sign-in pages a chat's card opened (CloudSignIn.tsx's Sign in, its automatic Claude page, and
/// GitHub's device page; ``AgentPaneSignInPage/allowed(_:)``), each with the closer of the tab that
/// open made, so the page's `browser.signInEnded` closes it once that sign-in ended (signed in,
/// Cancel, failed, expired or the card gone), as Settings' sign-in does (`LinkOpener.openSignInPage`,
/// `SignInPageTab`). Leo 2026-11-23: "WE ABSOLUELY MUST ERR ON THE SIDE OF BEING NOT ANNOYING": the
/// closer closes only a tab made since its open that is still on the page's host or the sign-in's own
/// hosts, never one the person took elsewhere or one that was there before.
///
/// Pure: the closers come from the app (``AgentPaneModel/onSignInTabCloser``) and run on the caller.
struct AgentPaneSignInTabs {
    typealias Closer = @MainActor (_ hosts: [String]) -> Void

    /// Most opens kept: an open whose sign-in never says it ended (a page that went away mid-load)
    /// is dropped, oldest first, rather than kept forever.
    static let limit = 8

    /// The opens, oldest first.
    private(set) var opens: [(url: URL, close: Closer)] = []

    /// Records the open of `url` with the closer of its tab. A second open of a page already
    /// recorded keeps the first: its closer saw the tabs from before both, so it closes the one tab
    /// either made, while the second's would count the first's tab as already there.
    mutating func opened(_ url: URL, close: @escaping Closer) {
        guard AgentPaneSignInPage.allowed(url), !opens.contains(where: { $0.url == url }) else { return }
        opens.append((url, close))
        if opens.count > Self.limit { opens.removeFirst(opens.count - Self.limit) }
    }

    /// The closers of the opens of `urls`, newest first, taken out (each closes at most once).
    mutating func ended(_ urls: [URL]) -> [Closer] {
        let ended = opens.filter { urls.contains($0.url) }
        opens.removeAll { urls.contains($0.url) }
        return ended.reversed().map(\.close)
    }

    /// Of the hosts a page names for an ended sign-in (acpmux's `pageHosts`), the ones a sign-in may
    /// own: a provider's sign-in host (``AgentPaneSignInPage/hosts``) or GitHub's; any other is
    /// dropped, so no page can have the person's own tab on another site closed.
    static func ownHosts(_ hosts: [String]) -> [String] {
        hosts.map { $0.lowercased() }.filter { AgentPaneSignInPage.hosts.contains($0) || $0 == AgentPaneSignInPage.githubDevicePage.host }
    }
}
