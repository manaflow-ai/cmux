import Foundation
import os

/// The media hub's scripts in a Chromium page (`BrowserMediaState+Scripts`),
/// through the DevTools protocol, so neither the fork nor the shim changes:
/// the observer runs in its own isolated world on every new document and
/// calls that world's `cmuxMedia` binding, whose calls arrive as
/// `Runtime.bindingCalled` events (`cmux_shim_devtools_watch_events`, kept
/// on through `CEFAgentRelay.mediaListens`, which hands them here first);
/// the action recorder runs in the page's world.
final class CEFMediaBridge {
    private unowned let tab: CEFTab

    init(tab: CEFTab) { self.tab = tab }

    /// The tab's browser exists (`CEFAgentRelay.browserAttached`).
    func attach(_ browser: Int32) {
        tab.agentRelay.mediaListens = true
        let observer = BrowserMediaState.observerScript(post: "\(BrowserMediaState.channel)(JSON.stringify(report))")
        let calls: [(String, [String: Any])] = [
            ("Runtime.addBinding", ["name": BrowserMediaState.channel, "executionContextName": BrowserMediaState.world]),
            ("Page.addScriptToEvaluateOnNewDocument", ["source": observer, "worldName": BrowserMediaState.world, "runImmediately": true]),
            ("Page.addScriptToEvaluateOnNewDocument", ["source": BrowserMediaState.actionsScript, "runImmediately": true]),
        ]
        Task { [weak tab] in
            for (method, params) in calls {
                guard let tab, tab.browserID == browser else { return }
                do {
                    _ = try await tab.runtime.devTools(browser, method: method, params: params)
                } catch {
                    tab.runtime.logger.info("media hub: \(method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// A `Runtime.bindingCalled` of the media binding: applies the page's
    /// report. False for every other message (the agent relay's).
    func handle(_ json: String) -> Bool {
        guard json.contains("\"Runtime.bindingCalled\""), json.contains("\"\(BrowserMediaState.channel)\""),
              let data = json.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["method"] as? String == "Runtime.bindingCalled",
              let params = message["params"] as? [String: Any], params["name"] as? String == BrowserMediaState.channel
        else { return false }
        if let payload = params["payload"] as? String, let media = BrowserMediaState.report(json: payload) {
            tab.machine.apply(.mediaChanged(media))
        }
        return true
    }
}
