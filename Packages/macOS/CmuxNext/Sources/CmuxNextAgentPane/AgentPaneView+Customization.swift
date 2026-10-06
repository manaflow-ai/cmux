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

    /// On the page host, runs the user's `registry.js` as a host script (the old host's scripts
    /// include it): the page's CSP (script-src 'self') refuses a script element the page makes.
    func runPageHostRegistry() {
        guard pageEvents != nil, let script = customization.registryScript else { return }
        evaluateScript(script)
    }

    /// Re-pushes a non-empty ``customization`` to a page that may not have
    /// had its bridge yet (a load finishing, the page asking for the
    /// handshake once its bridge exists).
    func replayCustomization() {
        guard !customization.isEmpty else { return }
        applyCustomization()
    }
}
