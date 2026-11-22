import Foundation

/// A Cloud chat's one-click sign-in (CloudSignIn.tsx; Leo 2026-11-02: one "Sign in to Claude"
/// button): the person's click starts the agent's own login on the machine
/// (`_acpmux/agent_login/start`, which takes the click's gesture), and that same start opens the
/// page the login names, once, with no second click (``AgentPaneTransport/takeSignInPage(_:)``).
/// Only a provider's own sign-in page over https may be opened this way: the hosts of acpmux's
/// `agent_login::parse::ALLOWED_HOSTS` and `CURSOR_HOSTS`, and the page's `SIGN_IN_HOSTS`.
enum AgentPaneSignInPage {
    static let hosts: Set<String> = [
        "claude.com",
        "claude.ai",
        "platform.claude.com",
        "console.anthropic.com",
        "auth.anthropic.com",
        "auth.openai.com",
        // The Grok CLI device flow (`grok login --device-auth`).
        "accounts.x.ai",
        "auth.x.ai",
        // Cursor's sign-in (`cursor-agent login`, acpmux `agent_login::parse::CURSOR_HOSTS`).
        "cursor.com",
    ]

    /// How long after the start the open may come: the machine reads its CLI's link for up to
    /// 20 s (acpmux `agent_login::URL_WAIT`), then the answer crosses the link back to this Mac.
    static let lifetime: TimeInterval = 90

    /// `url` is a provider sign-in page: https, no user info or port, on ``hosts``.
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// `browser.openIn`'s browser for Claude's automatic page (the page's `SIGN_IN_ON_MACHINE`): a
    /// Chromium tab of this app whose localhost is the chat's machine (``AgentPaneModel/onOpenSignInOnMachine``).
    static let chatMachineBrowser = "cmux-chat-machine"

    /// The port of Claude's own listener when `url` is its automatic page: an ``allowed(_:)`` page
    /// whose one `redirect_uri` is exactly `http://localhost:<port>/callback` (acpmux's
    /// `agent_login::parse::auto_url`). Nil for any other page.
    static func callbackPort(_ url: URL) -> UInt16? {
        guard allowed(url), let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let redirects = items.filter { $0.name == "redirect_uri" }
        guard redirects.count == 1, let redirect = redirects[0].value,
              redirect.hasPrefix("http://localhost:"), redirect.hasSuffix("/callback") else { return nil }
        let digits = redirect.dropFirst("http://localhost:".count).dropLast("/callback".count)
        guard let port = UInt16(digits), port > 0, String(port) == digits else { return nil }
        return port
    }
}

extension AgentPaneTransport {
    /// Spends the sign-in page credit a gesture-granted `_acpmux/agent_login/start` left on the
    /// current connection, for one open of `url`: true once, within ``AgentPaneSignInPage/lifetime``,
    /// and only for a provider sign-in page (any other URL leaves the credit).
    func takeSignInPage(_ url: URL) -> Bool {
        guard AgentPaneSignInPage.allowed(url) else { return false }
        return signInPageCredit.take(connection: current, now: gestures.uptime, lifetime: AgentPaneSignInPage.lifetime) == true
    }
}
