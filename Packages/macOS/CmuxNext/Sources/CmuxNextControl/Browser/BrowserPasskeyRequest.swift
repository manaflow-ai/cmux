/// One agent's ask that the person run a passkey ceremony in a browser tab.
///
/// The agent drove its own tab to the sign-in step; the person's click on the
/// request brings that tab forward and starts the ceremony there. No credential
/// data is in it, ever (plans/cmux-next/passkeys.md 3.5.4).
public struct BrowserPasskeyRequest: Sendable, Hashable {
    /// The request id; the banner and the Home card name it.
    public var id: String
    /// The browser tab (`tab_…`) the ceremony runs in.
    public var tabID: String
    /// The agent that asks (its display name, for example "Chief").
    public var agent: String
    /// The site, as the person reads it (the tab URL's host).
    public var site: String
    /// The agent's one-line reason, if it gave one.
    public var reason: String?

    /// - Parameters:
    ///   - id: the request id.
    ///   - tabID: the tab the ceremony runs in.
    ///   - agent: the asking agent's display name.
    ///   - site: the tab URL's host.
    ///   - reason: the agent's one-line reason, nil for none.
    public init(id: String, tabID: String, agent: String, site: String, reason: String? = nil) {
        self.id = id
        self.tabID = tabID
        self.agent = agent
        self.site = site
        self.reason = reason
    }
}
