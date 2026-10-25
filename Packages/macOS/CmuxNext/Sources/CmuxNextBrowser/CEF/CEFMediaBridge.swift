import Foundation

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
/// document commits and finishes, once that document's worlds exist; the
/// observer holds its report, with no timer, until the bridge's ready call
/// after each binding add (``CEFDocumentCall/readyHook(world:hook:)``) says
/// the binding is there.
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
        // Blink runs new-document scripts only while the Page domain is on; its events are a few
        // per navigation. The scripts are the same list the renderer path installs (`CEFDocumentScripts`).
        let scripts = CEFDocumentScripts(post: .binding).media.map { script -> CEFDocumentCall in
            var params: [String: Any] = ["source": script.source, "runImmediately": true]
            if !script.world.isEmpty { params["worldName"] = script.world }
            return .method("Page.addScriptToEvaluateOnNewDocument", params)
        }
        run([.method("Page.enable", [:])] + scripts + Self.documentCalls, browser)
        observation = ObservationLoop { [weak self] in self?.documentChanged() }
    }

    /// The calls for a document's worlds: the media world's bindings (the media report and the
    /// protected-media refusal), then the observer's ready hook, so a report that waited for the
    /// binding goes now, however late the binding came.
    static var documentCalls: [CEFDocumentCall] {
        [BrowserMediaState.channel, BrowserProtectedMedia.channel].map {
            .method("Runtime.addBinding", ["name": $0, "executionContextName": BrowserMediaState.world])
        } + [.readyHook(world: BrowserMediaState.world, hook: BrowserMediaState.readyHook)]
    }

    /// A document committed or finished: its world exists now.
    private func documentChanged() {
        guard let tab else { return }
        let state = tab.state
        guard state.phase == .committed || state.phase == .finished, let browser = tab.browserID else { return }
        let document = (url: state.url, phase: state.phase)
        guard boundDocument.map({ $0.url != document.url || $0.phase != document.phase }) ?? true else { return }
        boundDocument = document
        run(Self.documentCalls, browser)
    }

    private func run(_ calls: [CEFDocumentCall], _ browser: Int32) {
        guard let tab else { return }
        CEFDocumentCall.run(calls, on: tab, browser: browser, label: "media hub")
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
        if let payload = params["payload"] as? String { report(payload) }
        return true
    }

    /// One frame's media report (a binding call's payload, or a page channel post): untrusted JSON,
    /// `{frame, report}` (``BrowserMediaState/frameReport(json:)``).
    func report(_ payload: String) {
        guard let tab, let report = BrowserMediaState.frameReport(json: payload) else { return }
        tab.machine.apply(.mediaChanged(report.media, frame: report.frame))
        tab.keepAudioMute(after: report.media)
    }

    /// A refused protected media request: the key system's name, untrusted.
    func refused(_ payload: String) {
        guard let refused = BrowserProtectedMedia(reported: payload) else { return }
        tab?.emit(.protectedMediaUnavailable(refused))
    }
}

extension CEFTab: BrowserAudioMuting {
    public func setAudioMuted(_ muted: Bool) {
        machine.apply(.audioMutedChanged(muted))
        Task { await media(.muteTab(state.isAudioMuted)) }
    }
}
