import AppKit
import CmuxBrowser
import CmuxSettings
import Foundation

@MainActor
extension BrowserPanel {
    /// CEF currently has no per-workspace proxy/request-context seam. Keep
    /// remote panes on WebKit until those isolation guarantees exist instead
    /// of silently sending remote traffic directly or sharing local cookies.
    static func effectiveBrowserEngine(
        requested: BrowserEngineKind,
        isRemoteWorkspace: Bool,
        isURLAllowlistActive: Bool = false,
        initialURL: URL? = nil
    ) -> BrowserEngineKind {
        // CEF and the streamed child do not yet expose a request-interception
        // seam for page-initiated redirects/links. A configured URL allowlist
        // is therefore a security boundary: fail closed to WebKit, whose
        // navigation delegate enforces it for every request.
        let isTrustedCmuxScheme = initialURL?.scheme?.lowercased() == "cmux-diff-viewer"
        return requested == .chromium && (isRemoteWorkspace || isURLAllowlistActive || isTrustedCmuxScheme)
            ? .webkit
            : requested
    }

    /// Stops Chromium when its current workspace/policy no longer permits it.
    ///
    /// The compatibility ``WKWebView`` remains available for plumbing, but it
    /// is intentionally not promoted here: silently switching engines would
    /// change cookies and request routing under an existing page. A later
    /// explicit navigation after the policy is relaxed may start Chromium again.
    func enforceChromiumIsolationIfNeeded(reason: String) {
        guard isChromiumBacked, !chromiumIsolationPending else { return }
        let effective = Self.effectiveBrowserEngine(
            requested: .chromium,
            isRemoteWorkspace: isRemoteWorkspace,
            isURLAllowlistActive: BrowserURLAllowlistPolicy(defaults: .standard).isActive
        )
        guard effective == .webkit else { return }

        chromiumIsolationPending = true
        automationNavigationCoordinator.cancelExternalNavigation()
        automationNavigationCoordinator.invalidate()
        shouldRenderWebView = false
        isLoading = false
        canGoBack = false
        canGoForward = false
        pageTitle = String(
            localized: "browser.chromium.error.title",
            defaultValue: "Chromium unavailable"
        )
#if DEBUG
        cmuxDebugLog(
            "browser.chromium.isolation.blocked panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) remote=\(isRemoteWorkspace ? 1 : 0) " +
            "allowlist=\(BrowserURLAllowlistPolicy(defaults: .standard).isActive ? 1 : 0)"
        )
#endif
        refreshNavigationAvailability()

        let controller = browserEngineController
        chromiumIsolationTask = Task { @MainActor [weak self, controller] in
            await controller.stopAndWait()
            guard let self else { return }
            self.chromiumIsolationPending = false
            self.chromiumIsolationTask = nil
            self.refreshWebViewLifecycleState()
            self.refreshNavigationAvailability()
            if self.isWebViewVisibleInUI {
                self.restoreDeferredChromiumIfNeeded(reason: "isolation_complete")
            }
        }
    }

    func makeBrowserEngineController() -> BrowserPaneEngineController {
        let controller = BrowserPaneEngineController(
            kind: engineKind,
            webView: webView,
            profileID: profileID,
            storageID: chromiumStorageID,
            remoteDebuggingPort: configuredChromiumRemoteDebuggingPort,
            chromiumRuntimeEnvironment: .cmuxLive,
            chromiumNavigationPolicy: { [weak self] url in
                guard let self else { return true }
                return self.shouldBlockInsecureHTTPNavigation(to: url)
            }
        )
        controller.setChromiumSnapshotHandler { [weak self] snapshot in
            self?.applyChromiumSnapshot(snapshot)
        }
        controller.setChromiumFocusHandler { [weak self] in
            self?.noteChromiumContentFocused()
        }
        return controller
    }

    var isChromiumBacked: Bool {
        engineKind == .chromium
    }

    var isChromiumIsolationPendingForAutomation: Bool {
        chromiumIsolationPending
    }

    var chromiumContentView: NSView? {
        guard isChromiumBacked else { return nil }
        return browserEngineController.contentView
    }

    /// Returns the window that owns the selected browser content.
    ///
    /// CEF renders in a separate child window. Returning the host view's
    /// parent here makes focus probes inspect the wrong responder chain.
    var browserContentWindow: NSWindow? {
        if isChromiumBacked,
           let cef = browserEngineController.adapter as? CEFBrowserPaneEngineAdapter,
           cef.isBrowserWindowFocusReady {
            return cef.browserWindow ?? chromiumContentView?.window
        }
        return isChromiumBacked ? chromiumContentView?.window : webView.window
    }

    /// Returns the cmux window containing browser chrome (omnibar, find bar,
    /// and command-palette coordination). This differs from
    /// ``browserContentWindow`` only for CEF's adopted child window.
    var browserChromeWindow: NSWindow? {
        isChromiumBacked ? chromiumContentView?.window : webView.window
    }

    private var chromiumFocusTarget: (contentWindow: NSWindow, hostWindow: NSWindow, responder: NSView)? {
        guard isChromiumBacked else { return nil }
        if let cef = browserEngineController.adapter as? CEFBrowserPaneEngineAdapter {
            guard cef.isBrowserWindowFocusReady,
                  let window = cef.browserWindow,
                  let hostWindow = chromiumContentView?.window,
                  let responder = window.contentView else {
                return nil
            }
            return (window, hostWindow, responder)
        }
        guard let host = chromiumContentView, let window = host.window else { return nil }
        return (window, window, host)
    }

    var chromiumCDPEndpoint: BrowserCDPEndpoint? {
        guard isChromiumBacked else { return nil }
        return browserEngineController.remoteDebuggingEndpoint
    }

    /// Returns the actor-owned Chromium session for socket-worker automation.
    /// The session is Sendable and can be awaited without blocking the main
    /// actor; callers must not retain the AppKit adapter itself off-main.
    var chromiumSessionForAutomation: ChromiumBrowserSession? {
        guard isChromiumBacked,
              !chromiumIsolationPending,
              let chromium = browserEngineController.adapter as? ChromiumBrowserPaneEngineAdapter else {
            return nil
        }
        return chromium.session
    }

    /// A Sendable signal captured on the main actor alongside the session.
    /// Waiting for it guarantees document scripts, theme emulation, and the
    /// adapter's initial navigation have completed before socket automation.
    var chromiumStartupReadinessTaskForAutomation: Task<Void, Never>? {
        guard isChromiumBacked, !chromiumIsolationPending else { return nil }
        return browserEngineController.chromiumStartupReadinessTask
    }

    /// Reconciles child-process state into the panel's observable metadata.
    /// Chromium has no WebKit delegate callbacks, so this is the single
    /// adapter-to-panel mutation path for URL/title/loading/crash state.
    func applyChromiumSnapshot(_ snapshot: ChromiumSessionSnapshot) {
        if let url = snapshot.currentURL {
            currentURL = url
        }
        if let title = snapshot.title {
            pageTitle = title
        }
        switch snapshot.state {
        case .starting:
            isLoading = true
        case .running:
            isLoading = snapshot.isLoading
            shouldRenderWebView = true
            hasRecoverableWebContentTermination = false
            canGoBack = snapshot.canGoBack
            canGoForward = snapshot.canGoForward
            if !snapshot.isLoading,
               lastRecordedChromiumNavigationRevision != snapshot.navigationRevision,
               let url = snapshot.currentURL {
                historyStore.recordVisit(url: url, title: snapshot.title)
                lastRecordedChromiumNavigationRevision = snapshot.navigationRevision
            }
        case .crashed:
            isLoading = false
            lastRecordedChromiumNavigationRevision = nil
            hasRecoverableWebContentTermination = true
            canGoBack = false
            canGoForward = false
        case .failed(let message):
            isLoading = false
            canGoBack = false
            canGoForward = false
            #if DEBUG
            cmuxDebugLog("browser.chromium.start.failed error=\(message)")
            #endif
            pageTitle = String(
                localized: "browser.chromium.error.title",
                defaultValue: "Chromium unavailable"
            )
        case .stopped:
            isLoading = false
            lastRecordedChromiumNavigationRevision = nil
            canGoBack = false
            canGoForward = false
        }
        refreshWebViewLifecycleState()
    }

    /// Chromium panes retain an inert WKWebView for compatibility plumbing;
    /// their initial request must be applied to the managed child instead.
    func configureInitialChromiumNavigation(
        request: URLRequest?,
        url: URL?,
        shouldRender: Bool
    ) -> Bool {
        guard isChromiumBacked else { return false }
        let initialURL = request?.url ?? url
        if let initialURL {
            currentURL = initialURL
            shouldRenderWebView = shouldRender
            refreshWebViewLifecycleState()
            if shouldRender {
                guard BrowserURLAllowlistPolicy(defaults: .standard).allows(initialURL) else {
                    navigationDelegate?.blockURLAllowlistNavigation(initialURL, in: webView)
                    return true
                }
                let initialRequest = request ?? URLRequest(url: initialURL)
                if shouldBlockInsecureHTTPNavigation(to: initialURL) {
                    presentInsecureHTTPAlert(
                        for: initialRequest,
                        intent: .currentTab,
                        recordTypedNavigation: false
                    )
                } else {
                    startChromiumIfNeeded(initialURL: initialURL)
                }
            }
        }
        return true
    }

    /// Reveals a session-restored Chromium pane when its first visible host is
    /// mounted. The shared hidden-WebKit discard manager records the persisted
    /// render intent, but deliberately refuses to restore Chromium itself.
    func restoreDeferredChromiumIfNeeded(reason: String) {
        guard isChromiumBacked,
              !chromiumIsolationPending,
              Self.effectiveBrowserEngine(
                  requested: .chromium,
                  isRemoteWorkspace: isRemoteWorkspace,
                  isURLAllowlistActive: BrowserURLAllowlistPolicy(defaults: .standard).isActive
              ) == .chromium,
              !shouldRenderWebView,
              hiddenWebViewDiscardManager.restoredSessionShouldRenderWebView == true,
              let restoreURL = currentURL else { return }

        hiddenWebViewDiscardManager.clearDiscardState(reason: "chromium.\(reason)")
        shouldRenderWebView = true
        startChromiumIfNeeded(initialURL: restoreURL)
    }

    func applyChromiumProfileIdentity(
        _ nextProfileID: UUID,
        restoreURL: URL?,
        wasRenderable: Bool
    ) {
        profileID = nextProfileID
        historyStore = BrowserProfileStore.shared.historyStore(for: nextProfileID)
        BrowserProfileStore.shared.noteUsed(nextProfileID)
        lastRecordedChromiumNavigationRevision = nil
        hasRecoverableWebContentTermination = false
        canGoBack = false
        canGoForward = false
        isLoading = false
        webViewInstanceID = UUID()
        currentURL = restoreURL
        shouldRenderWebView = wasRenderable
        refreshWebViewLifecycleState()
    }

    func stopChromiumForContextResetIfNeeded() {
        guard isChromiumBacked else { return }
        stopChromium()
    }

    func rejectUnsupportedChromiumMuteChange(_ muted: Bool) -> Bool {
#if DEBUG
        cmuxDebugLog(
            "browser.audioMute.applyUnavailable panel=\(id.uuidString.prefix(5)) " +
            "reason=chromium_not_supported muted=\(muted ? 1 : 0)"
        )
#endif
        // The compatibility WKWebView is not the Chromium document. Do not
        // report success or mutate its state when Chromium owns the pane.
        return false
    }

    func captureChromiumVisibleViewportSnapshot(
        completion: @escaping (Result<NSImage, any Error>) -> Void,
        onFinish: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in
            defer { onFinish() }
            guard let self else { return }
            do {
                let data = try await screenshotChromium()
                guard let image = NSImage(data: data) else {
                    completion(.failure(BrowserScreenshotError.invalidImageRepresentation))
                    return
                }
                completion(.success(image))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func focusChromiumContentIfVisible() {
        guard shouldRenderWebView,
              let (contentWindow, hostWindow, responder) = chromiumFocusTarget,
              !responder.isHiddenOrHasHiddenAncestor else { return }
        // Keep cmux's registered parent window key for shortcut routing. The
        // adopted CEF child remains the responder target without becoming the
        // app's key-window identity.
        hostWindow.makeKey()
        if Self.responderChainContains(contentWindow.firstResponder, target: responder) {
            noteWebViewFocused()
        } else if contentWindow.makeFirstResponder(responder) {
            noteWebViewFocused()
        }
    }

    func requestChromiumContentFocus() -> Bool {
        guard shouldRenderWebView,
              let (contentWindow, hostWindow, responder) = chromiumFocusTarget,
              !responder.isHiddenOrHasHiddenAncestor else { return false }
        suppressOmnibarAutofocus(for: 1.5)
        hostWindow.makeKey()
        if Self.responderChainContains(contentWindow.firstResponder, target: responder) {
            return true
        }
        let didFocus = contentWindow.makeFirstResponder(responder)
        return didFocus
    }

    /// Reports focus against the actual engine window, including CEF's child
    /// window rather than the cmux host window.
    func isChromiumContentFocused() -> Bool {
        guard let (contentWindow, hostWindow, responder) = chromiumFocusTarget,
              hostWindow.isKeyWindow else { return false }
        return Self.responderChainContains(contentWindow.firstResponder, target: responder)
    }

    func chromiumContentOwnsResponder(_ responder: NSResponder) -> Bool {
        guard let target = chromiumFocusTarget?.responder else { return false }
        return Self.responderChainContains(responder, target: target)
    }

    func unfocusChromiumContent() {
        clearChromiumFocusState()
        guard let (contentWindow, _, responder) = chromiumFocusTarget else { return }
        if Self.responderChainContains(contentWindow.firstResponder, target: responder) {
            contentWindow.makeFirstResponder(nil)
        }
    }

    func clearChromiumFocusState() {
        guard let (contentWindow, _, responder) = chromiumFocusTarget else { return }
        guard Self.responderChainContains(contentWindow.firstResponder, target: responder) else {
            return
        }
        contentWindow.makeFirstResponder(nil)
    }

    func noteChromiumContentFocused() {
        noteWebViewFocused()
    }

    func canEnterChromiumFocusMode(searchIsActive: Bool, designModeIsActive: Bool) -> Bool {
        shouldRenderWebView &&
            chromiumFocusTarget?.responder.isHiddenOrHasHiddenAncestor == false &&
            !searchIsActive &&
            !designModeIsActive
    }

    func applyChromiumTheme(_ mode: BrowserThemeMode) {
        guard isChromiumBacked, !chromiumIsolationPending else { return }
        let scheme: String?
        switch mode {
        case .system:
            scheme = nil
        case .light:
            scheme = "light"
        case .dark:
            scheme = "dark"
        }
        (browserEngineController.adapter as? (any ChromiumEngineAdapting))?
            .setEmulatedColorScheme(scheme)
    }

    func startChromiumIfNeeded(initialURL: URL? = nil) {
        guard isChromiumBacked, !chromiumIsolationPending else { return }
        guard Self.effectiveBrowserEngine(
            requested: .chromium,
            isRemoteWorkspace: isRemoteWorkspace,
            isURLAllowlistActive: BrowserURLAllowlistPolicy(defaults: .standard).isActive
        ) == .chromium else {
            enforceChromiumIsolationIfNeeded(reason: "start_guard")
            return
        }
        browserEngineController.start(initialURL: initialURL)
    }

    func stopChromium() {
        guard isChromiumBacked else { return }
        browserEngineController.stop()
    }

    /// Replaces the Chromium child with the cmux-owned profile selected by the
    /// profile picker. Chromium's user-data directory is fixed at process
    /// launch, so changing only the panel's UUID would otherwise leave the
    /// old account active.
    @discardableResult
    func switchChromiumToProfile(_ requestedProfileID: UUID) -> Bool {
        guard isChromiumBacked,
              !chromiumIsolationPending,
              !preservesExplicitEphemeralWebsiteDataStoreForProfileSwitch else { return false }
        let resolvedProfileID = BrowserProfileStore.shared.profileDefinition(id: requestedProfileID) != nil
            ? requestedProfileID
            : BrowserProfileStore.shared.builtInDefaultProfileID
        guard resolvedProfileID != profileID else {
            BrowserProfileStore.shared.noteUsed(resolvedProfileID)
            return false
        }

        let wasRenderable = shouldRenderWebView
        let restoreURL = currentURL
        let shouldRestoreURL = wasRenderable &&
            restoreURL?.absoluteString != nil &&
            restoreURL?.absoluteString != "about:blank"

        guard browserEngineController.replaceChromium(
            profileID: resolvedProfileID,
            storageID: chromiumStorageID,
            remoteDebuggingPort: configuredChromiumRemoteDebuggingPort
        ) else { return false }
        applyChromiumProfileIdentity(
            resolvedProfileID,
            restoreURL: restoreURL,
            wasRenderable: wasRenderable
        )

        if shouldRestoreURL, let restoreURL {
            startChromiumIfNeeded(initialURL: restoreURL)
        } else if wasRenderable {
            startChromiumIfNeeded()
        }
        return true
    }

    func navigateChromium(to url: URL) {
        guard isChromiumBacked, !chromiumIsolationPending else { return }
        shouldRenderWebView = true
        startChromiumIfNeeded()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await self.browserEngineController.waitForStartupReadiness()
                try Task.checkCancellation()
                try await self.browserEngineController.adapter.navigate(to: url)
            } catch {
                self.applyChromiumSnapshot(
                    .init(state: .failed(ChromiumBrowserDiagnostic.operationEnded.message))
                )
            }
        }
    }

    func goBackChromium() {
        guard isChromiumBacked, !chromiumIsolationPending else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.browserEngineController.waitForStartupReadiness()
            guard !Task.isCancelled else { return }
            try? await self.browserEngineController.adapter.goBack()
        }
    }

    func goForwardChromium() {
        guard isChromiumBacked, !chromiumIsolationPending else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.browserEngineController.waitForStartupReadiness()
            guard !Task.isCancelled else { return }
            try? await self.browserEngineController.adapter.goForward()
        }
    }

    func reloadChromium() {
        guard isChromiumBacked, !chromiumIsolationPending else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.browserEngineController.waitForStartupReadiness()
            guard !Task.isCancelled else { return }
            try? await self.browserEngineController.adapter.reload()
        }
    }

    func evaluateChromiumJavaScript(
        _ script: String,
        awaitPromise: Bool = true
    ) async throws -> CDPValue {
        guard isChromiumBacked, !chromiumIsolationPending else { throw CDPError.notConnected }
        await browserEngineController.waitForStartupReadiness()
        try Task.checkCancellation()
        return try await browserEngineController.adapter.evaluateJavaScript(
            script,
            awaitPromise: awaitPromise
        )
    }

    func screenshotChromium() async throws -> Data {
        guard isChromiumBacked, !chromiumIsolationPending else { throw CDPError.notConnected }
        await browserEngineController.waitForStartupReadiness()
        try Task.checkCancellation()
        return try await browserEngineController.adapter.screenshotPNG()
    }

    /// A renderer crash is recoverable without touching the host app. The
    /// adapter starts a fresh child against the same cmux-owned profile and
    /// restores the last display URL.
    @discardableResult
    func recoverChromiumIfNeeded() -> Bool {
        guard isChromiumBacked,
              !chromiumIsolationPending,
              hasRecoverableWebContentTermination else { return false }
        hasRecoverableWebContentTermination = false
        let restoreURL = currentURL
        stopChromium()
        startChromiumIfNeeded(initialURL: restoreURL)
        return true
    }
}
