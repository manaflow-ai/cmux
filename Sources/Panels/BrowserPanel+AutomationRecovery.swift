import AppKit
import CmuxBrowser
import WebKit

extension BrowserPanel {
    func clearBrowserAutomationUserScripts() {
        engineInitializationScripts.removeAll()
        engineInitializationScriptCount = 0
        engineInitializationStyleCount = 0
    }

    func makeReplacementWebView(
        profileID: UUID,
        websiteDataStore: WKWebsiteDataStore
    ) -> CmuxWebView {
        Self.makeWebView(
            profileID: profileID,
            websiteDataStore: websiteDataStore
        )
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

        let pageJavaScriptProbe: BrowserAutomationWatchdog.Probe = { [weak self] finish in
            guard let self,
                  ObjectIdentifier(webView) == expectedWebViewIdentifier,
                  webViewInstanceID == observedWebViewInstanceID else {
                finish()
                return
            }
            Task { @MainActor [weak self] in
                guard let self,
                      ObjectIdentifier(webView) == expectedWebViewIdentifier,
                      webViewInstanceID == observedWebViewInstanceID else {
                    finish()
                    return
                }
                _ = try? await engineSession.evaluateJavaScript("true", in: .page)
                finish()
            }
        }
        let isolatedJavaScriptProbe: BrowserAutomationWatchdog.Probe = { [weak self] finish in
            guard let self,
                  ObjectIdentifier(webView) == expectedWebViewIdentifier,
                  webViewInstanceID == observedWebViewInstanceID else {
                finish()
                return
            }
            Task { @MainActor [weak self] in
                guard let self,
                      ObjectIdentifier(webView) == expectedWebViewIdentifier,
                      webViewInstanceID == observedWebViewInstanceID else {
                    finish()
                    return
                }
                _ = try? await engineSession.evaluateJavaScript("void 0", in: .isolated)
                finish()
            }
        }
        let snapshotProbe: BrowserAutomationWatchdog.Probe = { [weak self] finish in
            guard let self,
                  ObjectIdentifier(webView) == expectedWebViewIdentifier,
                  webViewInstanceID == observedWebViewInstanceID else {
                finish()
                return
            }
            Task { @MainActor [weak self] in
                guard let self,
                      ObjectIdentifier(webView) == expectedWebViewIdentifier,
                      webViewInstanceID == observedWebViewInstanceID else {
                    finish()
                    return
                }
                _ = try? await engineSession.captureScreenshot()
                finish()
            }
        }
        let outcome = await automationWatchdog.recoverIfUnresponsive(
            observedInstanceID: observedWebViewInstanceID,
            // Probe every engine-neutral automation channel so JavaScript and screenshot callers
            // can safely share this single in-flight responsiveness check.
            probes: [pageJavaScriptProbe, isolatedJavaScriptProbe, snapshotProbe],
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
