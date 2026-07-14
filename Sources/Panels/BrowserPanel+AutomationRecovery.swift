import AppKit
import CmuxBrowser
import WebKit

extension BrowserPanel {
    func recoverIfAutomationUnresponsive(
        expectedWebViewIdentifier: ObjectIdentifier,
        channel: BrowserAutomationProbeChannel
    ) async -> BrowserAutomationRecoveryOutcome {
        guard ObjectIdentifier(webView) == expectedWebViewIdentifier else { return .superseded }

        let outcome = await automationWatchdog.recoverIfUnresponsive(
            probe: { [weak self] finish in
                guard let self,
                      ObjectIdentifier(webView) == expectedWebViewIdentifier else {
                    finish()
                    return
                }
                switch channel {
                case .javaScript:
                    webView.evaluateJavaScript("void 0") { _, _ in finish() }
                case .snapshot:
                    let configuration = WKSnapshotConfiguration()
                    configuration.rect = NSRect(x: 0, y: 0, width: 1, height: 1)
                    webView.takeSnapshot(with: configuration) { _, _ in finish() }
                }
            },
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
