extension BrowserTab {
    /// The agent mark of the page cmux names this page's opener reaches it: an agent drives that page,
    /// so a page it made (a `window.open` or OAuth popup, whose script `window.opener` reaches) is the
    /// agent's too (no saved password, no passkey). An extension's own window (``isExtensionWindow``,
    /// a password manager's popout) is the person's UI and keeps no mark: the page did not make it and
    /// no page script reaches it, and a marked one would show `about:blank` in place of its
    /// `chrome-extension://` page. An agent that drives the window itself still marks it.
    /// - Parameter reading: the agent only reads the opener (``markAgentReading()``): the page is marked, its
    ///   WebAuthn stays as it is (an OAuth popup the person signs in to keeps their passkeys while the agent watches).
    public func takeOpenersAgentMark(reading: Bool = false) {
        guard !isExtensionWindow else { return }
        markAgent(reading: reading)
    }
}
