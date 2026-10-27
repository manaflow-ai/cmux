import Foundation
import os

/// The email verification detector in a Chromium page (`VerificationPageScripts`), through the
/// DevTools protocol like `CEFMediaBridge`: the detector runs in its own isolated world on every
/// new document and calls that world's `cmuxVerify` binding; the call arrives as a
/// `Runtime.bindingCalled` event (`CEFAgentRelay.deliver` hands it here). A report emits
/// `.verificationPageWaiting`. The binding is added again when a document commits and when it
/// finishes, as the media bridge does, since a binding reaches only worlds that exist when it is
/// added. Once per document, at `.finished` (after the detector's first check at
/// DOMContentLoaded), the bridge also calls the detector's ready hook in the existing worlds, so
/// a page found waiting before its binding existed reports then, with no timer in the page; a
/// page that shows later reports at its next show.
final class CEFVerificationBridge {
    /// Weak: the tab owns the relay that owns this bridge.
    private weak var tab: CEFTab?
    private var observation: ObservationLoop?
    private var boundDocument: (url: URL?, phase: BrowserLoadPhase)?

    init(tab: CEFTab) { self.tab = tab }

    private static var binding: (String, [String: Any]) {
        ("Runtime.addBinding", ["name": VerificationPageScripts.channel, "executionContextName": VerificationPageScripts.world])
    }

    /// Runs the detector's ready hook once in the worlds that exist now: `runImmediately` runs a
    /// new-document script in the existing worlds, and removing it at once keeps it off later
    /// documents (their detector finds the binding there from the start).
    private static func readyCall() -> (String, [String: Any]) {
        ("Page.addScriptToEvaluateOnNewDocument", ["source": readySource, "worldName": VerificationPageScripts.world, "runImmediately": true])
    }

    private static let readySource = "typeof window.\(VerificationPageScripts.readyHook) === 'function' && window.\(VerificationPageScripts.readyHook)()"

    /// The tab's browser exists (`CEFAgentRelay.browserAttached`).
    func attach(_ browser: Int32) {
        guard let tab else { return }
        let scripts = CEFDocumentScripts(post: .binding).verification.map { script -> (String, [String: Any]) in
            ("Page.addScriptToEvaluateOnNewDocument", ["source": script.source, "worldName": script.world, "runImmediately": true])
        }
        run([("Page.enable", [:])] + scripts + [Self.binding], browser, tab: tab)
        observation = ObservationLoop { [weak self] in self?.documentChanged() }
    }

    private func documentChanged() {
        guard let tab else { return }
        let state = tab.state
        guard state.phase == .committed || state.phase == .finished, let browser = tab.browserID else { return }
        let document = (url: state.url, phase: state.phase)
        guard boundDocument.map({ $0.url != document.url || $0.phase != document.phase }) ?? true else { return }
        boundDocument = document
        run(Self.documentCalls(phase: state.phase), browser, tab: tab)
    }

    /// The DevTools calls for a document that reached `phase`: the binding each time, the ready
    /// call (two round trips) only once the document finished.
    static func documentCalls(phase: BrowserLoadPhase) -> [(String, [String: Any])] {
        phase == .finished ? [binding, readyCall()] : [binding]
    }

    private func run(_ calls: [(String, [String: Any])], _ browser: Int32, tab: CEFTab) {
        // `CEFTab.runtime` is `unowned`, so it is read here, on the caller's turn while the runtime
        // is known alive, and held for the Task. `[weak tab]` guards the tab and never the runtime
        // behind it: a Task still draining after the runtime was destroyed read a dangling
        // `tab.runtime` and trapped in `swift_unownedRetainStrong`, which aborts the process in
        // `swift_abortRetainUnowned` rather than failing one call, so a test job that hit it stopped
        // reporting part-way through. Same shape as `CEFFirstPaintBridge.attach`.
        let runtime = tab.runtime
        Task { [weak tab] in
            for (method, params) in calls {
                guard let tab, tab.browserID == browser else { return }
                do {
                    let result = try await runtime.devTools(browser, method: method, params: params)
                    // The ready call is a one-shot: off every later document.
                    if params["source"] as? String == Self.readySource, let identifier = Self.scriptIdentifier(result) {
                        _ = try await runtime.devTools(browser, method: "Page.removeScriptToEvaluateOnNewDocument",
                                                       params: ["identifier": identifier])
                    }
                } catch {
                    runtime.logger.info("verification detector: \(method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// The `identifier` of a `Page.addScriptToEvaluateOnNewDocument` result.
    private static func scriptIdentifier(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["identifier"] as? String
    }

    /// A `Runtime.bindingCalled` of the detector's binding from the main frame's world: emits the
    /// report. False for every other message.
    func handle(_ json: String) -> Bool {
        guard json.contains("\"Runtime.bindingCalled\""), json.contains("\"\(VerificationPageScripts.channel)\""),
              let data = json.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["method"] as? String == "Runtime.bindingCalled",
              let params = message["params"] as? [String: Any], params["name"] as? String == VerificationPageScripts.channel
        else { return false }
        if let payload = params["payload"] as? String { report(payload) }
        return true
    }

    /// The detector's report (a binding payload or a page channel post), untrusted.
    func report(_ payload: String) {
        if VerificationPageScripts.isWaitingReport(payload) { tab?.emit(.verificationPageWaiting) }
    }
}
