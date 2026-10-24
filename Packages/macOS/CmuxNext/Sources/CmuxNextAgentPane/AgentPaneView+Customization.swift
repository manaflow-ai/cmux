import Foundation

/// The user's agent pane customization (``AgentPaneCustomization``: `theme.css`, `layout.json`,
/// `registry.js`) pushed to the page, on the page host and on the old host.
extension AgentPaneView {
    /// Pushes ``customization`` to the page, even an empty one (it clears
    /// what removed files left behind).
    func applyCustomization() {
        runPageHostRegistry()
        deliver(AgentPageEvent.customization(customization), scripts: customization.scripts())
    }

    /// On the page host, runs the user's `registry.js` as the page's host state script (the old
    /// host's scripts include it): the page's CSP (script-src 'self') refuses a script element the
    /// page makes. A push of the host's state: a frozen hidden page keeps only the newest and runs
    /// it at its thaw (``PageWebView/evaluateHostState(_:key:)``, PATTERNS.md P10); a host script
    /// here thawed it on every edit.
    func runPageHostRegistry() {
        guard pageEvents != nil, let page, let script = customization.registryScript else { return }
        page.evaluateHostState(script, key: "registry.js")
    }

    /// Re-pushes a non-empty ``customization`` to a page that may not have
    /// had its bridge yet (a load finishing, the page asking for the
    /// handshake once its bridge exists).
    func replayCustomization() {
        guard !customization.isEmpty else { return }
        applyCustomization()
    }
}
