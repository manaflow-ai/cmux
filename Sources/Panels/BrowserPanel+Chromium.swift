import AppKit
import CmuxBrowser
import Foundation

@MainActor
extension BrowserPanel {
    func makeBrowserEngineController() -> BrowserPaneEngineController {
        let controller = BrowserPaneEngineController(
            kind: engineKind,
            webView: webView,
            profileID: profileID,
            storageID: chromiumStorageID,
            remoteDebuggingPort: configuredChromiumRemoteDebuggingPort,
            chromiumRuntimeEnvironment: .cmuxLive
        )
        controller.setChromiumSnapshotHandler { [weak self] snapshot in
            self?.applyChromiumSnapshot(snapshot)
        }
        controller.setChromiumFocusHandler { [weak self] in
            self?.noteWebViewFocused()
        }
        return controller
    }

    var isChromiumBacked: Bool {
        engineKind == .chromium
    }

    var chromiumContentView: NSView? {
        guard isChromiumBacked else { return nil }
        return browserEngineController.contentView
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
              let chromium = browserEngineController.adapter as? ChromiumBrowserPaneEngineAdapter else {
            return nil
        }
        return chromium.session
    }

    /// A Sendable signal captured on the main actor alongside the session.
    /// Waiting for it guarantees document scripts, theme emulation, and the
    /// adapter's initial navigation have completed before socket automation.
    var chromiumStartupReadinessTaskForAutomation: Task<Void, Never>? {
        guard isChromiumBacked else { return nil }
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
        case .crashed:
            isLoading = false
            hasRecoverableWebContentTermination = true
            canGoBack = false
            canGoForward = false
        case .failed(let message):
            isLoading = false
            canGoBack = false
            canGoForward = false
            let format = String(
                localized: "browser.chromium.error.title",
                defaultValue: "Chromium unavailable: %@"
            )
            pageTitle = String.localizedStringWithFormat(format, message)
        case .stopped:
            isLoading = false
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
                startChromiumIfNeeded(initialURL: initialURL)
            }
        }
        return true
    }

    func applyChromiumProfileIdentity(
        _ nextProfileID: UUID,
        restoreURL: URL?,
        wasRenderable: Bool
    ) {
        profileID = nextProfileID
        historyStore = BrowserProfileStore.shared.historyStore(for: nextProfileID)
        BrowserProfileStore.shared.noteUsed(nextProfileID)
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
              let host = chromiumContentView,
              let window = host.window,
              !host.isHiddenOrHasHiddenAncestor else { return }
        if Self.responderChainContains(window.firstResponder, target: host) {
            noteWebViewFocused()
        } else if window.makeFirstResponder(host) {
            noteWebViewFocused()
        }
    }

    func requestChromiumContentFocus() -> Bool {
        guard shouldRenderWebView,
              let host = chromiumContentView,
              let window = host.window,
              !host.isHiddenOrHasHiddenAncestor else { return false }
        suppressOmnibarAutofocus(for: 1.5)
        return window.makeFirstResponder(host)
    }

    func unfocusChromiumContent() {
        guard let host = chromiumContentView, let window = host.window else { return }
        if Self.responderChainContains(window.firstResponder, target: host) {
            window.makeFirstResponder(nil)
        }
    }

    func canEnterChromiumFocusMode(searchIsActive: Bool, designModeIsActive: Bool) -> Bool {
        shouldRenderWebView &&
            chromiumContentView?.window != nil &&
            chromiumContentView?.isHiddenOrHasHiddenAncestor == false &&
            !searchIsActive &&
            !designModeIsActive
    }

    func applyChromiumTheme(_ mode: BrowserThemeMode) {
        let scheme: String?
        switch mode {
        case .system:
            scheme = nil
        case .light:
            scheme = "light"
        case .dark:
            scheme = "dark"
        }
        (browserEngineController.adapter as? ChromiumBrowserPaneEngineAdapter)?
            .setEmulatedColorScheme(scheme)
    }

    func startChromiumIfNeeded(initialURL: URL? = nil) {
        guard isChromiumBacked else { return }
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
        guard isChromiumBacked else { return }
        shouldRenderWebView = true
        startChromiumIfNeeded()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.browserEngineController.adapter.navigate(to: url)
            } catch {
                self.applyChromiumSnapshot(.init(state: .failed(error.localizedDescription)))
            }
        }
    }

    func goBackChromium() {
        guard isChromiumBacked else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.browserEngineController.adapter.goBack()
        }
    }

    func goForwardChromium() {
        guard isChromiumBacked else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.browserEngineController.adapter.goForward()
        }
    }

    func reloadChromium() {
        guard isChromiumBacked else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.browserEngineController.adapter.reload()
        }
    }

    func evaluateChromiumJavaScript(
        _ script: String,
        awaitPromise: Bool = true
    ) async throws -> CDPValue {
        guard isChromiumBacked else { throw CDPError.notConnected }
        return try await browserEngineController.adapter.evaluateJavaScript(
            script,
            awaitPromise: awaitPromise
        )
    }

    func screenshotChromium() async throws -> Data {
        guard isChromiumBacked else { throw CDPError.notConnected }
        return try await browserEngineController.adapter.screenshotPNG()
    }

    /// A renderer crash is recoverable without touching the host app. The
    /// adapter starts a fresh child against the same cmux-owned profile and
    /// restores the last display URL.
    @discardableResult
    func recoverChromiumIfNeeded() -> Bool {
        guard isChromiumBacked, hasRecoverableWebContentTermination else { return false }
        hasRecoverableWebContentTermination = false
        let restoreURL = currentURL
        stopChromium()
        startChromiumIfNeeded(initialURL: restoreURL)
        return true
    }
}
