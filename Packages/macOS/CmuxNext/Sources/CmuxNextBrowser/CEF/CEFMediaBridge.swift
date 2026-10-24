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
/// document commits and finishes, once that document's world exists, and
/// right after each add calls the observer's ready hook once in the existing
/// worlds (``BrowserMediaState/readyHook``): a report the observer held
/// because the binding was missing goes then, with no timer in the page.
final class CEFMediaBridge {
    /// Weak: the tab owns this bridge; after it is gone every entry point returns.
    private weak var tab: CEFTab?
    private var observation: ObservationLoop?
    /// The committed document the binding was last added for.
    private var boundDocument: (url: URL?, phase: BrowserLoadPhase)?

    init(tab: CEFTab) { self.tab = tab }

    /// The tab's browser exists (`CEFAgentRelay.browserAttached`).
    func attach(_ browser: Int32) {
        guard let tab else { return }
        tab.agentRelay.mediaListens = true
        let channel = BrowserMediaState.channel
        let observer = BrowserMediaState.observerScript(post: "\(channel)(JSON.stringify(message))", ready: "typeof \(channel) === 'function'")
        let script = { (source: String, world: String?) -> CEFDevToolsCall in
            var params: [String: Any] = ["source": source, "runImmediately": true]
            if let world { params["worldName"] = world }
            return .call(method: "Page.addScriptToEvaluateOnNewDocument", params: params)
        }
        let calls: [CEFDevToolsCall] = [
            // Blink runs new-document scripts only while the Page domain is
            // on; its events are a few per navigation.
            .call(method: "Page.enable", params: [:]),
            script(observer, BrowserMediaState.world),
            script(BrowserMediaState.actionsScript, nil),
            script(BrowserPageBusy.recorderScript, nil),
            // A refused Widevine request reopens the tab in WebKit (BrowserProtectedMedia).
            script(BrowserProtectedMedia.probeScript, nil),
            script(BrowserProtectedMedia.relayScript, BrowserMediaState.world),
        ] + Self.bindingCalls
        CEFDevToolsCall.run(calls, browser: browser, tab: tab, label: "media hub")
        observation = ObservationLoop { [weak self] in self?.documentChanged() }
    }

    /// The media world's bindings (the media report and the protected-media refusal), then the
    /// observer's ready hook in the worlds that exist now.
    static var bindingCalls: [CEFDevToolsCall] {
        [BrowserMediaState.channel, BrowserProtectedMedia.channel].map {
            .call(method: "Runtime.addBinding", params: ["name": $0, "executionContextName": BrowserMediaState.world])
        } + [.readyHook(BrowserMediaState.readyHook, world: BrowserMediaState.world)]
    }

    /// A document committed or finished: its world exists now.
    private func documentChanged() {
        guard let tab else { return }
        let state = tab.state
        guard state.phase == .committed || state.phase == .finished, let browser = tab.browserID else { return }
        let document = (url: state.url, phase: state.phase)
        guard boundDocument.map({ $0.url != document.url || $0.phase != document.phase }) ?? true else { return }
        boundDocument = document
        CEFDevToolsCall.run(Self.bindingCalls, browser: browser, tab: tab, label: "media hub")
    }

    /// A `Runtime.bindingCalled` of the media binding: applies the page's
    /// report. False for every other message (the agent relay's).
    func handle(_ json: String) -> Bool {
        if let refused = BrowserProtectedMedia.refused(bindingCall: json) {
            tab?.emit(.protectedMediaUnavailable(refused))
            return true
        }
        guard json.contains("\"Runtime.bindingCalled\""), json.contains("\"\(BrowserMediaState.channel)\""),
              let data = json.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["method"] as? String == "Runtime.bindingCalled",
              let params = message["params"] as? [String: Any], params["name"] as? String == BrowserMediaState.channel
        else { return false }
        if let tab, let payload = params["payload"] as? String, let report = BrowserMediaState.frameReport(json: payload) {
            tab.machine.apply(.mediaChanged(report.media, frame: report.frame))
            tab.keepAudioMute(after: report.media)
        }
        return true
    }
}

extension CEFTab: BrowserAudioMuting {
    public func setAudioMuted(_ muted: Bool) {
        machine.apply(.audioMutedChanged(muted))
        Task { await media(.muteTab(state.isAudioMuted)) }
    }
}
