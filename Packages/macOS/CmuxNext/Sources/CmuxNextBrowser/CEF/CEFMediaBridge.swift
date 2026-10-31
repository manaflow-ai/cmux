import CmuxNextCompat
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
    /// Weak: the tab owns this bridge; after it is gone every entry point returns.
    private weak var tab: CEFTab?
    /// The committed document the binding was last added for.
    private var boundDocument: (url: URL?, phase: BrowserLoadPhase)?

    init(tab: CEFTab) { self.tab = tab }

    /// The tab's browser exists (`CEFAgentRelay.browserAttached`).
    func attach(_ browser: Int32) {
        guard let tab else { return }
        tab.agentRelay.mediaListens = true
        // Blink runs new-document scripts only while the Page domain is on; its events are a few
        // per navigation. The scripts are the same list the renderer path installs (`CEFDocumentScripts`).
        let scripts = CEFDocumentScripts(post: .binding).media.map { script -> (String, [String: any Sendable]) in
            var params: [String: any Sendable] = ["source": script.source, "runImmediately": true]
            if !script.world.isEmpty { params["worldName"] = script.world }
            return ("Page.addScriptToEvaluateOnNewDocument", params)
        }
        let calls: [(String, [String: any Sendable])] = [("Page.enable", [:])] + scripts + Self.bindings
        run(calls, browser)
        documentChanged()
    }

    /// The media world's bindings: the media report and the protected-media refusal.
    private static var bindings: [(String, [String: any Sendable])] {
        [BrowserMediaState.channel, BrowserProtectedMedia.channel].map {
            ("Runtime.addBinding", ["name": $0, "executionContextName": BrowserMediaState.world])
        }
    }

    /// After attach, each shim event of the tab (`CEFAgentRelay.documentStateChanged`): a document
    /// that committed or finished has its world now.
    func documentChanged() {
        guard let tab else { return }
        let state = tab.state
        guard state.phase == .committed || state.phase == .finished, let browser = tab.browserID else { return }
        let document = (url: state.url, phase: state.phase)
        guard boundDocument.map({ $0.url != document.url || $0.phase != document.phase }) ?? true else { return }
        boundDocument = document
        run(Self.bindings, browser)
    }

    private func run(_ calls: [(String, [String: any Sendable])], _ browser: Int32) {
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
        if let refused = BrowserProtectedMedia.refused(bindingCall: json) {
            tab?.emit(.protectedMediaUnavailable(refused))
            return true
        }
        guard json.contains("\"Runtime.bindingCalled\""), json.contains("\"\(BrowserMediaState.channel)\""),
              let data = json.data(using: .utf8),
              let message = try? JSONSerialization.blockingJSONObject(with: data) as? [String: Any],
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
        tab.noteAudible()
        tab.keepAudioMute(after: report.media)
    }

    /// A refused protected media request: the key system's name, untrusted.
    func refused(_ payload: String) {
        guard let refused = BrowserProtectedMedia(reported: payload) else { return }
        tab?.emit(.protectedMediaUnavailable(refused))
    }
}

extension CEFTab: BrowserAudibleReporting {
    /// Copies `state.media?.isAudible` into `isAudible` when it flipped. Each event that changes
    /// `media` calls it: a media report, a commit, a renderer exit.
    func noteAudible() {
        let audible = state.media?.isAudible == true
        if audible != isAudible { isAudible = audible }
    }
}

extension CEFTab: BrowserAudioMuting {
    public func setAudioMuted(_ muted: Bool) {
        machine.apply(.audioMutedChanged(muted))
        Task { await media(.muteTab(state.isAudioMuted)) }
    }
}
