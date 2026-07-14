import AppKit
import CmuxBrowser
import WebKit

extension BrowserPanel {
    func recoverIfAutomationUnresponsive(
        expectedWebViewIdentifier: ObjectIdentifier,
        channel: BrowserAutomationProbeChannel
    ) async -> BrowserAutomationRecoveryOutcome {
        guard ObjectIdentifier(webView) == expectedWebViewIdentifier else { return .superseded }

        let asyncJavaScriptProbe: BrowserAutomationWatchdog.Probe = { [weak self] finish in
            guard let self,
                  ObjectIdentifier(webView) == expectedWebViewIdentifier else {
                finish()
                return
            }
            webView.callAsyncJavaScript(
                "return true",
                arguments: [:],
                in: nil,
                in: .page
            ) { _ in finish() }
        }
        let evaluationProbe: BrowserAutomationWatchdog.Probe = { [weak self] finish in
            guard let self,
                  ObjectIdentifier(webView) == expectedWebViewIdentifier else {
                finish()
                return
            }
            webView.evaluateJavaScript("void 0") { _, _ in finish() }
        }
        let snapshotProbe: BrowserAutomationWatchdog.Probe = { [weak self] finish in
            guard let self,
                  ObjectIdentifier(webView) == expectedWebViewIdentifier else {
                finish()
                return
            }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = NSRect(x: 0, y: 0, width: 1, height: 1)
            webView.takeSnapshot(with: configuration) { _, _ in finish() }
        }
        let probes: [BrowserAutomationWatchdog.Probe]
        switch channel {
        case .javaScript:
            probes = [asyncJavaScriptProbe]
        case .screenshot:
            probes = [evaluationProbe, snapshotProbe]
        }

        let outcome = await automationWatchdog.recoverIfUnresponsive(
            probes: probes,
            recover: { [weak self] in
                self?.replaceWebViewAfterAutomationTimeout(
                    expectedWebViewIdentifier: expectedWebViewIdentifier,
                    reason: "automation_\(channel.debugName)_unresponsive"
                ) ?? false
            }
        )

        if outcome == .responsive,
           ObjectIdentifier(webView) != expectedWebViewIdentifier {
            return .superseded
        }
        return outcome
    }
}
