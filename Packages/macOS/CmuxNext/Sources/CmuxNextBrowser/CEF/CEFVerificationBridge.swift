import Foundation

/// The email verification detector in a Chromium page (`VerificationPageScripts`), through the
/// DevTools protocol like `CEFMediaBridge`: the detector runs in its own isolated world on every
/// new document and calls that world's `cmuxVerify` binding; the call arrives as a
/// `Runtime.bindingCalled` event (`CEFAgentRelay.deliver` hands it here). A report emits
/// `.verificationPageWaiting`. The binding is added again when a document commits and when it
/// finishes, as the media bridge does, since a binding reaches only worlds that exist when it is
/// added. After each of those binding adds the bridge also calls the detector's ready hook in the
/// existing worlds, so a page found waiting before its binding existed reports then, with no
/// timer in the page: at `.committed` (a page whose load never ends) and at `.finished` (after
/// the detector's first check at DOMContentLoaded). A page that shows later reports at its next
/// show.
final class CEFVerificationBridge {
    /// Weak: the tab owns the relay that owns this bridge.
    private weak var tab: CEFTab?
    private var observation: ObservationLoop?
    /// The document phase the calls were last sent for.
    private var gate = CEFDocumentGate()

    init(tab: CEFTab) { self.tab = tab }

    private static var binding: CEFDocumentCall {
        .method("Runtime.addBinding", ["name": VerificationPageScripts.channel, "executionContextName": VerificationPageScripts.world])
    }

    /// The detector's ready hook, once in the worlds that exist now (``CEFDocumentCall/readyHook(world:hook:)``).
    private static var readyCall: CEFDocumentCall {
        .readyHook(world: VerificationPageScripts.world, hook: VerificationPageScripts.readyHook)
    }

    /// The tab's browser exists (`CEFAgentRelay.browserAttached`).
    func attach(_ browser: Int32) {
        guard let tab else { return }
        let scripts = CEFDocumentScripts(post: .binding).verification.map { script -> CEFDocumentCall in
            .method("Page.addScriptToEvaluateOnNewDocument", ["source": script.source, "worldName": script.world, "runImmediately": true])
        }
        CEFDocumentCall.run([.method("Page.enable", [:])] + scripts + [Self.binding], on: tab, browser: browser, label: "verification detector")
        observation = ObservationLoop { [weak self] in self?.documentChanged() }
    }

    private func documentChanged() {
        guard let tab else { return }
        let state = tab.state
        guard let browser = tab.browserID else { return }
        let calls = Self.callsOnChange(document: tab.committedDocument, phase: state.phase, gate: &gate)
        guard !calls.isEmpty else { return }
        CEFDocumentCall.run(calls, on: tab, browser: browser, label: "verification detector")
    }

    /// The calls for one observed change of the tab: ``documentCalls(phase:)`` once per document
    /// at `.committed` and at `.finished` (``CEFDocumentGate``), none for an address change within
    /// the document (`pushState`, `replaceState`).
    static func callsOnChange(document: BrowserNavigationID?, phase: BrowserLoadPhase, gate: inout CEFDocumentGate) -> [CEFDocumentCall] {
        gate.admits(document: document, phase: phase) ? documentCalls(phase: phase) : []
    }

    /// The DevTools calls for a document that reached `phase` (`.committed` or `.finished`): the
    /// binding, then the ready call (two round trips).
    static func documentCalls(phase: BrowserLoadPhase) -> [CEFDocumentCall] {
        [binding, readyCall]
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
