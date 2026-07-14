import CmuxBrowser
import Foundation
import WebKit

extension TerminalController {
    nonisolated func v2CaptureBrowserAutomationSnapshot(
        _ browserPanel: BrowserPanel,
        timeout: TimeInterval
    ) -> BrowserAutomationSnapshotResult? {
        socketAwaitCallback(timeout: timeout) { finish in
            v2MainSync {
                browserPanel.captureAutomationVisibleViewportSnapshot { result in
                    switch result {
                    case .success(let image):
                        guard let data = self.v2PNGData(from: image) else {
                            finish(.failure(BrowserScreenshotError.invalidImageRepresentation.localizedDescription))
                            return
                        }
                        finish(.success(data))
                    case .failure(let error as BrowserScreenshotError):
                        if case .automationTimedOut = error {
                            finish(.timedOut)
                        } else {
                            finish(.failure(error.localizedDescription))
                        }
                    case .failure(let error):
                        finish(.failure(error.localizedDescription))
                    }
                }
            }
        }
    }

    nonisolated func v2RecoverTimedOutBrowserJavaScript(
        _ result: V2JavaScriptResult,
        webView: WKWebView,
        surfaceId: UUID
    ) -> V2JavaScriptResult {
        guard case .failure(let message) = result,
              message == "Timed out waiting for JavaScript result" else {
            return result
        }
        return .failure(v2BrowserAutomationMessageAfterLivenessCheck(
            originalMessage: message,
            surfaceId: surfaceId,
            expectedWebViewIdentifier: ObjectIdentifier(webView),
            channel: .javaScript
        ))
    }

    nonisolated func v2BrowserAutomationMessageAfterLivenessCheck(
        originalMessage: String,
        surfaceId: UUID,
        expectedWebViewIdentifier: ObjectIdentifier,
        channel: BrowserAutomationProbeChannel
    ) -> String {
        let outcome: BrowserAutomationRecoveryOutcome? = socketAwaitCallback(timeout: 2.5) { finish in
            Task { @MainActor in
                guard let app = AppDelegate.shared else {
                    finish(.superseded)
                    return
                }
                let panel = app.windowDockContainingPanel(surfaceId)?.browserPanel(for: surfaceId)
                    ?? app.workspaceContainingPanel(panelId: surfaceId)?.workspace.browserPanel(for: surfaceId)
                guard let panel else {
                    finish(.superseded)
                    return
                }
                let result = await panel.recoverIfAutomationUnresponsive(
                    expectedWebViewIdentifier: expectedWebViewIdentifier,
                    channel: channel
                )
#if DEBUG
                cmuxDebugLog(
                    "browser.automation.liveness surface=\(surfaceId.uuidString.prefix(5)) " +
                    "channel=\(channel.debugName) outcome=\(String(describing: result))"
                )
#endif
                finish(result)
            }
        }

        switch outcome {
        case .recovered:
            return String(
                localized: "browser.automation.error.recovered",
                defaultValue: "The browser surface stopped responding and was recovered. Retry the command."
            )
        case .superseded:
            return String(
                localized: "browser.automation.error.superseded",
                defaultValue: "The browser surface was already recovered. Retry the command."
            )
        case .responsive, .cancelled, nil:
            return originalMessage
        }
    }
}
