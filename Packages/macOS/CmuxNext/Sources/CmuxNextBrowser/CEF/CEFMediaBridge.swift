import Foundation
import os

/// The media hub's scripts in a Chromium page (`BrowserMediaState+Scripts`),
/// through the DevTools protocol, so neither the fork nor the shim changes:
/// the observer runs in its own isolated world on every new document and
/// calls that world's `cmuxMedia` binding, whose calls arrive as
/// `Runtime.bindingCalled` events (`cmux_shim_devtools_watch_events`, kept
/// on through `CEFAgentRelay.mediaListens`, which hands them here first);
/// the action recorder runs in the page's world.
///
/// Without `Runtime.enable` (which would stream every console message of
/// every tab, and which pages can detect) a binding reaches only worlds
/// that exist when it is added. So the bridge adds it again each time a
/// document commits, once that document's world exists; the observer holds
/// its report until the binding appears.
final class CEFMediaBridge {
    private unowned let tab: CEFTab
    private var observation: ObservationLoop?
    /// The committed document the binding was last added for.
    private var boundDocument: (url: URL?, phase: BrowserLoadPhase)?

    init(tab: CEFTab) { self.tab = tab }

    /// The tab's browser exists (`CEFAgentRelay.browserAttached`).
    func attach(_ browser: Int32) {
        tab.agentRelay.mediaListens = true
        let channel = BrowserMediaState.channel
        let observer = BrowserMediaState.observerScript(post: "\(channel)(JSON.stringify(report))", ready: "typeof \(channel) === 'function'")
        let calls: [(String, [String: Any])] = [
            ("Page.addScriptToEvaluateOnNewDocument", ["source": observer, "worldName": BrowserMediaState.world, "runImmediately": true]),
            ("Page.addScriptToEvaluateOnNewDocument", ["source": BrowserMediaState.actionsScript, "runImmediately": true]),
            Self.binding,
        ]
        run(calls, browser)
        observation = ObservationLoop { [weak self] in self?.documentChanged() }
    }

    private static var binding: (String, [String: Any]) {
        ("Runtime.addBinding", ["name": BrowserMediaState.channel, "executionContextName": BrowserMediaState.world])
    }

    /// A document committed or finished: its world exists now.
    private func documentChanged() {
        let state = tab.state
        guard state.phase == .committed || state.phase == .finished, let browser = tab.browserID else { return }
        let document = (url: state.url, phase: state.phase)
        guard boundDocument.map({ $0.url != document.url || $0.phase != document.phase }) ?? true else { return }
        boundDocument = document
        run([Self.binding], browser)
    }

    private func run(_ calls: [(String, [String: Any])], _ browser: Int32) {
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
