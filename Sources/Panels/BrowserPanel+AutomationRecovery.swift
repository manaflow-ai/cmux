import AppKit
import CmuxBrowser
import CmuxSettings
import WebKit

extension BrowserPanel {
    func setupSameDocumentNavigationMessageHandler(for webView: WKWebView) {
        let observedWebViewInstanceID = webViewInstanceID
        let handler = BrowserSameDocumentNavigationMessageHandler(
            webView: webView,
            onNavigation: { [weak self, weak webView] url in
                guard let self, let webView,
                      self.webView === webView,
                      self.webViewInstanceID == observedWebViewInstanceID else {
                    return
                }
                let displayURL = Self.remoteProxyDisplayURL(for: url) ?? url
                self.automationNavigationCoordinator.didFinishSameDocumentNavigation(
                    instanceID: observedWebViewInstanceID,
                    url: displayURL
                )
            }
        )
        sameDocumentNavigationMessageHandler = handler
        let userContentController = webView.configuration.userContentController
        userContentController.removeScriptMessageHandler(
            forName: BrowserSameDocumentNavigationMessageHandler.name,
            contentWorld: BrowserSameDocumentNavigationMessageHandler.contentWorld
        )
        userContentController.add(
            handler,
            contentWorld: BrowserSameDocumentNavigationMessageHandler.contentWorld,
            name: BrowserSameDocumentNavigationMessageHandler.name
        )
    }

    private func startChromiumAutomationNavigation(
        _ ticket: BrowserAutomationNavigationTicket,
        targetURL: URL?,
        reload: Bool = false,
        recordTypedNavigation: Bool = false
    ) {
        automationNavigationCoordinator.startExternalNavigation(ticket) { [weak self] in
            guard let self else { throw CancellationError() }
            guard !self.chromiumIsolationPending else { throw CDPError.notConnected }
            self.shouldRenderWebView = true
            self.startChromiumIfNeeded()
            if recordTypedNavigation, let targetURL {
                self.historyStore.recordTypedNavigation(url: targetURL)
            }
            if let cef = self.browserEngineController.adapter as? CEFBrowserPaneEngineAdapter {
                await cef.startupReadinessTask?.value
                try Task.checkCancellation()
                guard !self.chromiumIsolationPending else { throw CDPError.notConnected }
                let revision = cef.currentNavigationRevision()
                if reload {
                    try await cef.reload()
                } else if let targetURL {
                    try await cef.navigate(to: targetURL)
                }
                guard !self.chromiumIsolationPending else { throw CDPError.notConnected }
                try await cef.waitForNavigation(to: reload ? nil : targetURL, after: revision)
                guard !self.chromiumIsolationPending else { throw CDPError.notConnected }
                return
            }
            guard let session = self.chromiumSessionForAutomation else {
                throw CDPError.notConnected
            }
            let revision = await session.currentNavigationRevision()
            guard !self.chromiumIsolationPending else { throw CDPError.notConnected }
            if reload {
                try await self.browserEngineController.adapter.reload()
            } else if let targetURL {
                try await self.browserEngineController.adapter.navigate(to: targetURL)
            }
            guard !self.chromiumIsolationPending else { throw CDPError.notConnected }
            try await session.waitForNavigation(to: nil, after: revision)
            guard !self.chromiumIsolationPending else { throw CDPError.notConnected }
        }
    }

    func beginAutomationNavigation(
        to targetURL: URL,
        recordTypedNavigation: Bool
    ) -> BrowserAutomationNavigationTicket {
        if chromiumIsolationPending {
            let ticket = automationNavigationCoordinator.begin(
                instanceID: webViewInstanceID,
                targetURL: targetURL,
                allowsSameDocumentCompletion: false
            )
            automationNavigationCoordinator.finishExternally(ticket, with: .cancelled)
            return ticket
        }
        if isChromiumBacked, !chromiumIsolationPending {
            let ticket = automationNavigationCoordinator.begin(
                instanceID: webViewInstanceID,
                targetURL: targetURL,
                allowsSameDocumentCompletion: true
            )
            guard BrowserURLAllowlistPolicy(defaults: .standard).allows(targetURL) else {
                navigationDelegate?.blockURLAllowlistNavigation(targetURL, in: webView)
                automationNavigationCoordinator.finishExternally(ticket, with: .cancelled)
                return ticket
            }
            if shouldBlockInsecureHTTPNavigation(to: targetURL) {
                presentInsecureHTTPAlert(
                    for: URLRequest(url: targetURL),
                    intent: .currentTab,
                    recordTypedNavigation: recordTypedNavigation,
                    onResolution: { [weak self] resolution in
                        guard let self else { return }
                        if case .proceededInCurrentTab = resolution {
                            self.startChromiumAutomationNavigation(
                                ticket,
                                targetURL: targetURL,
                                recordTypedNavigation: recordTypedNavigation
                            )
                        } else {
                            self.automationNavigationCoordinator.finishExternally(ticket, with: .cancelled)
                        }
                    },
                    deferNavigation: true
                )
            } else {
                startChromiumAutomationNavigation(
                    ticket,
                    targetURL: targetURL,
                    recordTypedNavigation: recordTypedNavigation
                )
            }
            return ticket
        }
        let ticket = automationNavigationCoordinator.begin(
            instanceID: webViewInstanceID,
            targetURL: targetURL,
            allowsSameDocumentCompletion: navigationDelegate?.activeErrorPageDisplayURL == nil
                && navigationDelegate?.activePolicyBlockedURL == nil
        )
        navigate(
            to: targetURL,
            recordTypedNavigation: recordTypedNavigation,
            onNavigationStarted: { [weak self] navigation in
                self?.automationNavigationCoordinator.didStart(
                    ticket,
                    navigationID: navigation.map { ObjectIdentifier($0) }
                )
            }
        )
        return ticket
    }

    func beginAutomationReloadFromCLI() -> (
        ticket: BrowserAutomationNavigationTicket,
        targetURL: URL
    )? {
        guard let targetURL = automationReloadTargetURL() else { return nil }
        guard !chromiumIsolationPending else { return nil }
        if isChromiumBacked, !chromiumIsolationPending {
            let ticket = automationNavigationCoordinator.begin(
                instanceID: webViewInstanceID,
                targetURL: targetURL
            )
            startChromiumAutomationNavigation(ticket, targetURL: targetURL, reload: true)
            return (ticket, targetURL)
        }
        let ticket = automationNavigationCoordinator.begin(
            instanceID: webViewInstanceID,
            targetURL: targetURL
        )
        let navigationStarted: (WKNavigation?) -> Void = { [weak self] navigation in
            self?.automationNavigationCoordinator.didStart(
                ticket,
                navigationID: navigation.map { ObjectIdentifier($0) }
            )
        }

        switch navigationDelegate?.activeErrorPageRetryForAutomation() {
        case .request(let request):
            navigateWithoutInsecureHTTPPrompt(
                request: request,
                recordTypedNavigation: false,
                onNavigationStarted: navigationStarted
            )
        case .urlOnly:
            navigate(
                to: targetURL,
                recordTypedNavigation: false,
                onNavigationStarted: navigationStarted
            )
        case .disabled:
            navigationStarted(nil)
        case nil:
            if let navigation = reload() {
                navigationStarted(navigation)
            } else {
                automationNavigationCoordinator.didReturnNoNavigation(
                    ticket,
                    hasCurrentHistoryItem: webView.backForwardList.currentItem != nil,
                    isShowingNewTabPage: isShowingNewTabPage,
                    waitsForDeferredNavigation: webView.isLoading ||
                        isMainFrameProvisionalNavigationActive ||
                        hasPendingRemoteNavigation
                )
            }
        }
        return (ticket, targetURL)
    }

    func finishAutomationNavigation(
        _ ticket: BrowserAutomationNavigationTicket
    ) async -> BrowserAutomationNavigationOutcome {
        await automationNavigationCoordinator.wait(for: ticket)
    }

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
        if isChromiumBacked,
           !chromiumIsolationPending,
           let chromium = browserEngineController.adapter as? (any ChromiumEngineAdapting) {
            chromium.clearDocumentScripts()
        }
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
        if isChromiumBacked, !chromiumIsolationPending {
            guard ObjectIdentifier(webView) == expectedWebViewIdentifier else { return .superseded }
            do {
                // A bounded Runtime.evaluate is the Chromium liveness probe;
                // an unverified target must never be reported as healthy.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor [weak self] in
                        guard let self else { throw CancellationError() }
                        _ = try await self.browserEngineController.adapter.evaluateJavaScript(
                            "true",
                            awaitPromise: false
                        )
                    }
                    group.addTask {
                        try await ContinuousClock().sleep(for: .seconds(2))
                        throw ChromiumBrowserDiagnostic.commandTimedOut
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
                return .responsive
            } catch {
                return .cancelled
            }
        }
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
        guard !isChromiumBacked else { return false }
        guard ObjectIdentifier(webView) == expectedWebViewIdentifier, canRecoverFromAutomationTimeout else { return false }
        replaceWebViewPreservingState(
            from: webView,
            websiteDataStore: websiteDataStore,
            reason: reason
        )
        return true
    }
}
