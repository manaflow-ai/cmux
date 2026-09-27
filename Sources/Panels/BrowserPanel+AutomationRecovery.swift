import CmuxCloud
import AppKit
import CmuxBrowser
import WebKit

/// The bounded result of preparing one browser WebView for automation input.
enum BrowserAutomationDocumentReadinessResult: Sendable, Equatable {
    case committed
    case superseded
    case cancelled
    case timedOut
}

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

    func setupDocumentReadyMessageHandler(for webView: WKWebView) {
        let observedWebViewInstanceID = webViewInstanceID
        let handler = BrowserDocumentReadyMessageHandler(
            webView: webView,
            onDocumentReady: { [weak self, weak webView] in
                guard let self, let webView,
                      self.webView === webView,
                      self.webViewInstanceID == observedWebViewInstanceID else {
                    return
                }
                self.automationDocumentReadiness.didSignalDocumentReady(
                    instanceID: observedWebViewInstanceID
                )
#if DEBUG
                cmuxDebugLog(
                    "browser.documentReadyBridge panel=\(self.id.uuidString.prefix(5)) " +
                    "instance=\(observedWebViewInstanceID.uuidString.prefix(6))"
                )
#endif
            }
        )
        documentReadyMessageHandler = handler
        let userContentController = webView.configuration.userContentController
        userContentController.removeScriptMessageHandler(
            forName: BrowserDocumentReadyMessageHandler.name,
            contentWorld: BrowserDocumentReadyMessageHandler.contentWorld
        )
        userContentController.add(
            handler,
            contentWorld: BrowserDocumentReadyMessageHandler.contentWorld,
            name: BrowserDocumentReadyMessageHandler.name
        )
    }

    func tearDownDocumentReadyMessageHandler(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserDocumentReadyMessageHandler.name,
            contentWorld: BrowserDocumentReadyMessageHandler.contentWorld
        )
        documentReadyMessageHandler = nil
    }

    /// Returns lifecycle-only state for diagnosing automation readiness failures.
    ///
    /// The payload deliberately excludes document contents, cookies, and page JavaScript values.
    func browserAutomationReadinessPayload() -> [String: Any] {
        let snapshot = automationDocumentReadiness.snapshot
        return [
            "ready": snapshot.isReady,
            "signal": snapshot.signal?.rawValue ?? "none",
            "document_ready_bridge_registered": documentReadyMessageHandler != nil,
            "navigation_delegate_registered": webView.navigationDelegate != nil,
            "history_item_present": webView.backForwardList.currentItem != nil,
            "is_loading": webView.isLoading,
            "estimated_progress": webView.estimatedProgress,
            "web_content_terminated": webContentState.isTerminated
        ]
    }

    func beginAutomationNavigation(
        to targetURL: URL,
        recordTypedNavigation: Bool
    ) -> BrowserAutomationNavigationTicket {
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

        if !retryFailedNavigationForReload(mode: .soft, onNavigationStarted: navigationStarted) {
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
    }

    func makeReplacementWebView(
        profileID: UUID,
        websiteDataStore: WKWebsiteDataStore
    ) -> CmuxWebView {
        let replacementStore: WKWebsiteDataStore
        if cloudAccess.model?.usesBrowserProxy == true {
            if let endpoint = cloudAccess.model?.browserProxy,
               let address = cloudAccess.model?.target.host {
                websiteDataStore.proxyConfigurations = [
                    CloudBrowserRouting.configuration(endpoint: endpoint, address: address)
                ]
                replacementStore = websiteDataStore
            } else {
                // Keep the Cloud store unused until its first network session
                // can be created with the authenticated proxy already set.
                replacementStore = .nonPersistent()
            }
        } else {
            replacementStore = websiteDataStore
        }
        let replacement = Self.makeWebView(
            profileID: profileID,
            websiteDataStore: replacementStore
        )
        for userScript in browserAutomationUserScripts {
            replacement.configuration.userContentController.addUserScript(userScript)
        }
        if cloudAccess.model?.usesBrowserProxy == true, let host = cloudAccess.remoteURL?.host {
            replacement.configuration.userContentController.addUserScript(WKUserScript(
                source: RemoteLoopbackRuntimeBridge.scriptSource(aliasHost: host, preservesSubdomains: false),
                injectionTime: .atDocumentStart, forMainFrameOnly: false
            ))
            if let endpoint = cloudAccess.model?.browserProxy {
                CloudBrowserRouting.installWebSocketBridge(endpoint: endpoint, address: host, on: replacement)
            }
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

    /// Ensures that the current WebView instance has a committed document without
    /// blocking the socket worker or the main actor.
    @MainActor
    func ensureAutomationDocumentReady(
        expectedWebViewIdentifier: ObjectIdentifier,
        timeout: Duration = .seconds(3),
        reason: String
    ) async -> BrowserAutomationDocumentReadinessResult {
        guard !Task.isCancelled else { return .cancelled }
        guard ObjectIdentifier(webView) == expectedWebViewIdentifier,
              let blankURL = URL(string: "about:blank") else {
            return .superseded
        }

        if webView.url == nil,
           !webView.isLoading,
           webView.backForwardList.currentItem == nil {
            // Discarded tabs preserve the user's page intent. Restore it before
            // falling back to a real about:blank document for an empty new tab.
            let restored = restoreDiscardedWebViewIfNeeded(reason: reason)
            if !restored, let preserved = currentURL {
                navigate(to: preserved)
            } else if !restored || Self.isAboutBlankURL(currentURL) {
                navigate(to: blankURL)
            }
        }

        guard ObjectIdentifier(webView) == expectedWebViewIdentifier else {
            return .superseded
        }

        return await withTaskGroup(of: BrowserAutomationDocumentReadinessResult.self) { group in
            group.addTask { [weak self] in
                guard let self else { return .cancelled }
                switch await self.waitForAutomationDocumentCommit(
                    expectedWebViewIdentifier: expectedWebViewIdentifier
                ) {
                case .committed: return .committed
                case .superseded: return .superseded
                case .cancelled: return .cancelled
                }
            }
            group.addTask {
                do {
                    // This is the command's real readiness deadline, not a settle/poll delay.
                    try await ContinuousClock().sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let result = await group.next() ?? .cancelled
            group.cancelAll()
            return result
        }
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
