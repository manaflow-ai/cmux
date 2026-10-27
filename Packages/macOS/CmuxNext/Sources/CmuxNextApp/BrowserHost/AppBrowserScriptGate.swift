import CmuxNextBrowser
import CmuxNextBrowserHost
import CmuxNextControl
import Foundation

/// The browser host's Secure Store login guard (``ProviderScriptGate``, cmux
/// https://github.com/manaflow-ai/cmux/issues/25830): the app's one ``BrowserAgentCodeGate``,
/// with each tab's current URL and browser profile read from its live page (else its record).
final class AppBrowserScriptGate: ProviderScriptGate {
    private weak var services: AppServices?
    let gate: BrowserAgentCodeGate

    init(services: AppServices, gate: BrowserAgentCodeGate) {
        self.services = services
        self.gate = gate
    }

    func admitAgentCode(targetID: String) async -> String? {
        let (url, profile) = page(targetID)
        return await gate.admit(tabID: targetID, url: url, profile: profile)
    }

    func agentCodeRan(targetID: String) async {
        let (url, profile) = page(targetID)
        await gate.ran(tabID: targetID, url: url, profile: profile)
    }

    func admitRawDevTools(targetID: String) async -> String? {
        let (url, profile) = page(targetID)
        return await gate.admitRaw(tabID: targetID, url: url, profile: profile)
    }

    func rawDevToolsMessage(targetID: String) -> String? {
        let (url, profile) = page(targetID)
        return gate.rawMessage(url: url, profile: profile)
    }

    /// The tab's current URL and browser profile id, as the control socket's topology names it.
    private func page(_ targetID: String) -> (url: String?, profile: String?) {
        guard let services else { return (nil, nil) }
        let cache: TabContentCache = services.cache
        let page = cache.existingBrowser(targetID)?.tab
        let url = page?.state.url?.absoluteString ?? cache.tabModel(targetID)?.url
        // As the topology names it (ControlTopologyMapper), so both paths key the same sites.
        let profile = cache.tabModel(targetID)?.browserProfileID ?? "default"
        return (url, profile)
    }
}
