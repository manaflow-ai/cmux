import AppKit
import CmuxBrowser
import WebKit

extension BrowserPanel {
    func registerBrowserAutomationInitScript(_ userScript: WKUserScript) -> Int {
        browserAutomationUserScripts.append(userScript)
        browserAutomationInitScriptCount += 1
        webView.configuration.userContentController.addUserScript(userScript)
        return browserAutomationInitScriptCount
    }

    func registerBrowserAutomationStyleScript(_ userScript: WKUserScript) -> Int {
        browserAutomationUserScripts.append(userScript)
        browserAutomationStyleScriptCount += 1
        webView.configuration.userContentController.addUserScript(userScript)
        return browserAutomationStyleScriptCount
    }

    func clearBrowserAutomationUserScripts() {
        browserAutomationUserScripts.removeAll()
        browserAutomationInitScriptCount = 0
        browserAutomationStyleScriptCount = 0
    }

    func makeReplacementWebView(
        profileID: UUID,
        websiteDataStore: WKWebsiteDataStore
    ) -> CmuxWebView {
        let replacement = Self.makeWebView(
            profileID: profileID,
            websiteDataStore: websiteDataStore
        )
        for userScript in browserAutomationUserScripts {
            replacement.configuration.userContentController.addUserScript(userScript)
        }
        return replacement
    }

    var canRecoverFromAutomationTimeout: Bool {
        !isClosingWebViewLifecycle &&
            activeInteractiveBrowserPromptIDs.isEmpty &&
            activeVisualAutomationCaptureCount == 0
    }

    func waitForAutomationDocumentCommit(
        expectedWebViewIdentifier: ObjectIdentifier
    ) async -> BrowserAutomationDocumentReadinessOutcome {
        guard ObjectIdentifier(webView) == expectedWebViewIdentifier else { return .superseded }
        return await automationDocumentReadiness.waitForCommit(instanceID: webViewInstanceID)
    }

    func recoverIfAutomationUnresponsive(
        expectedWebViewIdentifier: ObjectIdentifier,
        channel: BrowserAutomationProbeChannel
    ) async -> BrowserAutomationRecoveryOutcome {
        guard ObjectIdentifier(webView) == expectedWebViewIdentifier else { return .superseded }
        guard canRecoverFromAutomationTimeout else { return .responsive }
        let observedWebViewInstanceID = webViewInstanceID

        let asyncJavaScriptProbe: BrowserAutomationWatchdog.Probe = { [weak self] finish in
            guard let self,
                  ObjectIdentifier(webView) == expectedWebViewIdentifier,
                  webViewInstanceID == observedWebViewInstanceID else {
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
                  ObjectIdentifier(webView) == expectedWebViewIdentifier,
                  webViewInstanceID == observedWebViewInstanceID else {
                finish()
                return
            }
            webView.evaluateJavaScript("void 0") { _, _ in finish() }
        }
        let snapshotProbe: BrowserAutomationWatchdog.Probe = { [weak self] finish in
            guard let self,
                  ObjectIdentifier(webView) == expectedWebViewIdentifier,
                  webViewInstanceID == observedWebViewInstanceID else {
                finish()
                return
            }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = NSRect(x: 0, y: 0, width: 1, height: 1)
            webView.takeSnapshot(with: configuration) { _, _ in finish() }
        }
        let outcome = await automationWatchdog.recoverIfUnresponsive(
            observedInstanceID: observedWebViewInstanceID,
            // One WebContent process services every automation API. Probing all callback channels
            // lets JavaScript and screenshot callers safely share this single in-flight check.
            probes: [asyncJavaScriptProbe, evaluationProbe, snapshotProbe],
            recover: { [weak self] in
                self?.replaceWebViewAfterAutomationTimeout(
                    expectedWebViewIdentifier: expectedWebViewIdentifier,
                    reason: "automation_\(channel.debugName)_unresponsive"
                ) ?? false
            }
        )

        if outcome == .responsive,
           (ObjectIdentifier(webView) != expectedWebViewIdentifier
               || webViewInstanceID != observedWebViewInstanceID) {
            return .superseded
        }
        return outcome
    }

    @discardableResult
    func replaceWebViewAfterAutomationTimeout(
        expectedWebViewIdentifier: ObjectIdentifier,
        reason: String
    ) -> Bool {
        guard ObjectIdentifier(webView) == expectedWebViewIdentifier, canRecoverFromAutomationTimeout else { return false }
        replaceWebViewPreservingState(
            from: webView,
            websiteDataStore: websiteDataStore,
            reason: reason
        )
        return true
    }
}
