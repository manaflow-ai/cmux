import CmuxBrowser
import Foundation
import WebKit

extension TerminalController {
    nonisolated func v2AwaitBrowserAutomationNavigation(
        _ ticket: BrowserAutomationNavigationTicket,
        browserPanel: BrowserPanel
    ) -> BrowserAutomationNavigationOutcome? {
        var navigationTask: Task<Void, Never>?
        let outcome: BrowserAutomationNavigationOutcome? = socketAwaitCallback(timeout: 17.5) { finish in
            navigationTask = Task { @MainActor in
                finish(await browserPanel.finishAutomationNavigation(ticket))
            }
        }
        if outcome == nil {
            navigationTask?.cancel()
        }
        return outcome
    }

    nonisolated func v2BrowserNavigationFailureResult(
        _ outcome: BrowserAutomationNavigationOutcome?,
        targetURL: URL
    ) -> V2CallResult? {
        let data: [String: Any] = ["url": targetURL.absoluteString]
        switch outcome {
        case .committed, .downloaded:
            return nil
        case .failed:
            return .err(
                code: "navigation_failed",
                message: String(
                    localized: "cli.browser.error.operationFailed",
                    defaultValue: "Browser operation failed"
                ),
                data: data
            )
        case .cancelled:
            return .err(
                code: "navigation_cancelled",
                message: String(
                    localized: "cli.browser.error.operationFailed",
                    defaultValue: "Browser operation failed"
                ),
                data: data
            )
        case .superseded:
            return .err(
                code: "stale_state",
                message: String(
                    localized: "browser.automation.error.superseded",
                    defaultValue: "The browser surface was already recovered. Retry the command."
                ),
                data: data
            )
        case .notStarted:
            return .err(
                code: "navigation_failed",
                message: String(
                    localized: "cli.browser.error.operationFailed",
                    defaultValue: "Browser operation failed"
                ),
                data: data
            )
        case .timedOut, nil:
            return .err(
                code: "navigation_timeout",
                message: String(
                    localized: "browser.automation.error.documentReadinessTimedOut",
                    defaultValue: "Timed out waiting for the browser document to become ready"
                ),
                data: data
            )
        }
    }

    nonisolated func v2CaptureBrowserAutomationSnapshot(
        _ browserPanel: BrowserPanel,
        timeout: TimeInterval
    ) -> (webViewIdentifier: ObjectIdentifier, result: BrowserAutomationSnapshotResult)? {
        socketAwaitCallback(timeout: timeout) { finish in
            v2MainSync {
                let webViewIdentifier = ObjectIdentifier(browserPanel.webView)
                browserPanel.captureAutomationVisibleViewportSnapshot { result in
                    switch result {
                    case .success(let image):
                        guard let data = self.v2PNGData(from: image) else {
                            finish((webViewIdentifier, .failure(BrowserScreenshotError.invalidImageRepresentation.localizedDescription)))
                            return
                        }
                        finish((webViewIdentifier, .success(data)))
                    case .failure(let error as BrowserScreenshotError):
                        if case .automationTimedOut = error {
                            finish((webViewIdentifier, .timedOut))
                        } else {
                            finish((webViewIdentifier, .failure(error.localizedDescription)))
                        }
                    case .failure(let error):
                        finish((webViewIdentifier, .failure(error.localizedDescription)))
                    }
                }
            }
        }
    }

    nonisolated func v2RecoverTimedOutBrowserJavaScript(
        _ result: BrowserJavaScriptEvaluationResult,
        webView: WKWebView,
        browserPanel: BrowserPanel,
        surfaceId: UUID
    ) -> V2JavaScriptResult {
        switch result {
        case .success(let value):
            return .success(value)
        case .failure(let message):
            return .failure(message)
        case .timedOut:
            return .failure(v2BrowserAutomationMessageAfterLivenessCheck(
                originalMessage: String(
                    localized: "browser.automation.error.javaScriptTimedOut",
                    defaultValue: "Timed out waiting for JavaScript result"
                ),
                browserPanel: browserPanel,
                surfaceId: surfaceId,
                expectedWebViewIdentifier: ObjectIdentifier(webView),
                channel: .javaScript
            ))
        }
    }

    nonisolated func v2BrowserAutomationMessageAfterLivenessCheck(
        originalMessage: String,
        browserPanel: BrowserPanel,
        surfaceId: UUID,
        expectedWebViewIdentifier: ObjectIdentifier,
        channel: BrowserAutomationProbeChannel
    ) -> String {
        var recoveryTask: Task<Void, Never>?
        let outcome: BrowserAutomationRecoveryOutcome? = socketAwaitCallback(timeout: 2.5) { finish in
            recoveryTask = Task { @MainActor in
                guard !Task.isCancelled else {
                    finish(.cancelled)
                    return
                }
                let result = await browserPanel.recoverIfAutomationUnresponsive(
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
        if outcome == nil {
            recoveryTask?.cancel()
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
