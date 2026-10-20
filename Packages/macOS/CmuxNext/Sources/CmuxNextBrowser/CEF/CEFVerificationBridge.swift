import Foundation
import os

/// The email verification detector in a Chromium page (`VerificationPageScripts`), through the
/// DevTools protocol like `CEFMediaBridge`: the detector runs in its own isolated world on every
/// new document and calls that world's `cmuxVerify` binding; the call arrives as a
/// `Runtime.bindingCalled` event (`CEFAgentRelay.deliver` hands it here). A report emits
/// `.verificationPageWaiting`. The binding is added again when a document commits, as the
/// media bridge does, since a binding reaches only worlds that exist when it is added.
final class CEFVerificationBridge {
    /// Weak: the tab owns the relay that owns this bridge.
    private weak var tab: CEFTab?
    private var observation: ObservationLoop?
    private var boundDocument: (url: URL?, phase: BrowserLoadPhase)?

    init(tab: CEFTab) { self.tab = tab }

    private static var binding: (String, [String: Any]) {
        ("Runtime.addBinding", ["name": VerificationPageScripts.channel, "executionContextName": VerificationPageScripts.world])
    }

    /// The tab's browser exists (`CEFAgentRelay.browserAttached`).
    func attach(_ browser: Int32) {
        guard let tab else { return }
        let channel = VerificationPageScripts.channel
        let detector = VerificationPageScripts.detectorScript(post: "\(channel)(JSON.stringify(report))", ready: "typeof \(channel) === 'function'")
        run([
            ("Page.enable", [:]),
            ("Page.addScriptToEvaluateOnNewDocument", ["source": detector, "worldName": VerificationPageScripts.world, "runImmediately": true]),
            Self.binding,
        ], browser, tab: tab)
        observation = ObservationLoop { [weak self] in self?.documentChanged() }
    }

    private func documentChanged() {
        guard let tab else { return }
        let state = tab.state
        guard state.phase == .committed || state.phase == .finished, let browser = tab.browserID else { return }
        let document = (url: state.url, phase: state.phase)
        guard boundDocument.map({ $0.url != document.url || $0.phase != document.phase }) ?? true else { return }
        boundDocument = document
        run([Self.binding], browser, tab: tab)
    }

    private func run(_ calls: [(String, [String: Any])], _ browser: Int32, tab: CEFTab) {
        Task { [weak tab] in
            for (method, params) in calls {
                guard let tab, tab.browserID == browser else { return }
                do {
                    _ = try await tab.runtime.devTools(browser, method: method, params: params)
                } catch {
                    tab.runtime.logger.info("verification detector: \(method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
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
        if let payload = params["payload"] as? String, VerificationPageScripts.isWaitingReport(payload) {
            tab?.emit(.verificationPageWaiting)
        }
        return true
    }
}
