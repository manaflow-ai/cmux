import CmuxBrowser
import CmuxCEF
import Foundation

/// The tab's speaker in a Chromium page: the media-playback hook WebKit
/// pages run (``BrowserMediaPlaybackScript``), through the DevTools protocol.
///
/// The hook runs in its own isolated world in every new document and posts
/// through that world's binding, whose calls arrive as `Runtime.bindingCalled`
/// events (`cmux_shim_devtools_watch_events`); page scripts cannot reach the
/// binding to fake a report. Without `Runtime.enable` (which would stream
/// every console message and which pages can detect) a binding reaches only
/// the worlds that exist when it is added, so it is added again whenever a
/// frame navigates or stops loading; the hook holds a report until then.
/// Out-of-process frames are separate DevTools targets and report nothing.
extension CEFBrowserPage {
    /// The isolated world the hook runs in.
    nonisolated static let mediaPlaybackWorld = "cmuxMediaPlayback"
    /// The binding the hook posts through, in ``mediaPlaybackWorld`` only.
    nonisolated static let mediaPlaybackBinding = "cmuxMediaPlayback"

    /// What a protocol message means to the hook.
    enum MediaPlaybackSignal: Equatable {
        /// A frame reported its playback.
        case report(BrowserMediaPlaybackReport)
        /// A new main-frame document committed: earlier frames are gone.
        case mainDocumentCommitted
        /// A frame navigated or stopped loading: its world may be new.
        case frameChanged
    }

    /// The protocol calls that install the hook, in order. Blink runs
    /// new-document scripts only while the Page domain is on.
    nonisolated static func mediaPlaybackSetupCalls() -> [(method: String, params: [String: Any])] {
        let source = BrowserMediaPlaybackScript.source(
            post: "\(mediaPlaybackBinding)(JSON.stringify(report))",
            ready: "typeof \(mediaPlaybackBinding) === 'function'"
        )
        return [
            ("Page.enable", [:]),
            ("Page.addScriptToEvaluateOnNewDocument", [
                "source": source, "worldName": mediaPlaybackWorld, "runImmediately": true,
            ]),
            mediaPlaybackBindingCall,
        ]
    }

    nonisolated static var mediaPlaybackBindingCall: (method: String, params: [String: Any]) {
        ("Runtime.addBinding", ["name": mediaPlaybackBinding, "executionContextName": mediaPlaybackWorld])
    }

    /// Installs the hook in browser `id`, synchronously, before its first
    /// load (and again for a browser Chromium creates later for the page).
    func installMediaPlaybackHook(browserID id: Int32) {
        guard let shim = shimProvider() else { return }
        shim.devToolsWatchEvents(id, 1)
        for call in Self.mediaPlaybackSetupCalls() {
            _ = shim.devToolsCall(id, call.method, Self.json(call.params))
        }
    }

    /// The hook's meaning of one raw protocol message, or nil.
    nonisolated static func mediaPlaybackSignal(forProtocolMessage json: String) -> MediaPlaybackSignal? {
        // Cheap checks first: every protocol event of the page comes here.
        let isBinding = json.contains("\"Runtime.bindingCalled\"")
        let isNavigated = json.contains("\"Page.frameNavigated\"")
        guard isBinding || isNavigated || json.contains("\"Page.frameStoppedLoading\"") else { return nil }
        guard let message = jsonObject(json), let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "Runtime.bindingCalled":
            guard params["name"] as? String == mediaPlaybackBinding,
                  let payload = params["payload"] as? String,
                  let report = BrowserMediaPlaybackReport(json: payload) else { return nil }
            return .report(report)
        case "Page.frameNavigated":
            let frame = params["frame"] as? [String: Any]
            return frame?["parentId"] == nil ? .mainDocumentCommitted : .frameChanged
        case "Page.frameStoppedLoading":
            return .frameChanged
        default:
            return nil
        }
    }

    /// Applies one protocol message of the page to the hook.
    func receiveMediaPlaybackMessage(_ json: String) {
        switch Self.mediaPlaybackSignal(forProtocolMessage: json) {
        case .report(let report)?:
            emit(.mediaPlaybackReported(report))
        case .mainDocumentCommitted?:
            emit(.mediaPlaybackReset)
            refreshMediaPlaybackBinding()
        case .frameChanged?:
            refreshMediaPlaybackBinding()
        case nil:
            break
        }
    }

    /// Adds the binding again, once for a burst of frame events.
    private func refreshMediaPlaybackBinding() {
        guard !mediaBindingRefreshPending else { return }
        mediaBindingRefreshPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.mediaBindingRefreshPending = false
            guard let id = self.browser.browserID, let shim = self.shimProvider() else { return }
            let call = Self.mediaPlaybackBindingCall
            _ = shim.devToolsCall(id, call.method, Self.json(call.params))
        }
    }
}
