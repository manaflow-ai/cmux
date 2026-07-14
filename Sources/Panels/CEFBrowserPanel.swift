import AppKit
import CEFKit
import Combine
import CmuxSettings
import Foundation
import OSLog

nonisolated let cefBrowserLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "CEFBrowser"
)

/// A first-pass Chromium Embedded Framework browser hosted as a cmux panel.
/// CEFKit guarantees that delegate callbacks arrive on the main thread; its
/// delegate protocol predates actor annotations, so the conformance is imported
/// with `@preconcurrency` while this panel remains main-actor isolated.
@MainActor
final class CEFBrowserPanel: Panel, OmnibarHostingPanel, @preconcurrency CEFBrowserDelegate {
    private struct CEFProfileResolution {
        let profile: CEFProfile?
    }

    let id: UUID
    let workspaceId: UUID
    let profileID: UUID
    let historyStore: BrowserHistoryStore
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .cefBrowser
    let containerView: CEFBrowserContainerView
    let hostView: CEFBrowserHostView

    @Published var currentURL: String
    @Published private(set) var title: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var pendingAddressBarFocusRequestId: UUID?
    private(set) var pendingAddressBarFocusSelectionIntent: BrowserAddressBarFocusSelectionIntent =
        .preserveFieldEditorSelection

    private(set) var browser: CEFBrowser?
    private var cefProfile: CEFProfile?
    private var hasStarted = false
    private var isCreatingBrowser = false
    private var isClosing = false
    private var wantsFocus = false
    private var isAddressFieldFocused = false
    private(set) var isVisibleInUI = true
    private var pendingNavigationURL: String?
    private var lastEmbeddedURL: String

    var cefProfileName: String {
        profileID.uuidString.lowercased()
    }

    /// Keeps the panel and its browser alive while asynchronous CEF teardown runs.
    private var closingRetain: CEFBrowserPanel?

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        return String(
            localized: "command.openCefBrowser.title",
            defaultValue: "Chromium Browser (CEF)"
        )
    }

    var displayIcon: String? { "globe" }

    init(
        id: UUID = UUID(),
        workspaceId: UUID,
        profileID: UUID? = nil,
        historyStore: BrowserHistoryStore? = nil,
        initialURL: String = "about:blank"
    ) {
        let resolvedProfileID = profileID ?? BrowserProfileStore.shared.builtInDefaultProfileID
        let containerView = CEFBrowserContainerView(frame: .zero)
        self.id = id
        self.workspaceId = workspaceId
        self.profileID = resolvedProfileID
        self.historyStore = historyStore ?? BrowserProfileStore.shared.historyStore(for: resolvedProfileID)
        self.currentURL = initialURL
        self.lastEmbeddedURL = initialURL
        self.containerView = containerView
        self.hostView = CEFBrowserHostView(containerView: containerView)
    }

    /// Starts the embedded browser after the process-wide CEF context is ready.
    func start(url rawURL: String) {
        guard !hasStarted, !isClosing else { return }
        guard CEFRuntimeSupport.isRuntimeBundled else {
            cefBrowserLogger.error("CEF runtime is not bundled")
            return
        }

        do {
            try CEFRuntimeSupport.startIfNeeded()
        } catch {
            cefBrowserLogger.error("CEF initialization failed: \(String(describing: error), privacy: .private)")
            return
        }

        let initialURL = Self.normalizedURLString(rawURL) ?? "about:blank"
        currentURL = initialURL
        lastEmbeddedURL = initialURL
        hasStarted = true
        CEFApp.shared.onContextInitialized { [weak self] in
            self?.createBrowser(url: initialURL)
        }
    }

    /// Navigates the embedded browser, or opens `chrome://` URLs in CEF's Chrome-style window.
    func navigate(to rawURL: String) {
        guard !isClosing, let normalizedURL = Self.normalizedURLString(rawURL) else { return }
        historyStore.recordTypedNavigation(url: URL(string: normalizedURL))

        if URL(string: normalizedURL)?.scheme?.lowercased() == "chrome" {
            currentURL = lastEmbeddedURL
            openChromeStyleWindow(url: normalizedURL)
            return
        }

        currentURL = normalizedURL
        lastEmbeddedURL = normalizedURL
        if let browser {
            browser.load(url: normalizedURL)
        } else if hasStarted {
            pendingNavigationURL = normalizedURL
        } else {
            start(url: normalizedURL)
        }
    }

    func goBack() {
        browser?.goBack()
    }

    func goForward() {
        browser?.goForward()
    }

    func reload() {
        browser?.reload()
    }

    func stopLoading() {
        browser?.stopLoad()
    }

    func navigateSmart(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let url = resolveNavigableURL(from: trimmed) {
            navigate(to: url.absoluteString)
            return
        }

        let searchConfiguration = BrowserSearchSettingsStore().currentConfiguration
        guard let searchURL = searchConfiguration.searchURL(query: trimmed) else { return }
        navigate(to: searchURL.absoluteString)
    }

    func resolveNavigableURL(from input: String) -> URL? {
        if let url = resolveBrowserNavigableURL(input) {
            return url
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let hasSupportedOpaqueScheme = ["about:", "chrome:", "data:", "javascript:", "mailto:"].contains {
            lowercased.hasPrefix($0)
        }
        return hasSupportedOpaqueScheme ? URL(string: trimmed) : nil
    }

    func preferredURLStringForOmnibar() -> String? {
        let trimmed = currentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "about:blank" else { return nil }
        return trimmed
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        wantsFocus = false
        pendingNavigationURL = nil

        if isCreatingBrowser {
            closingRetain = self
            return
        }

        guard let browser else { return }
        closingRetain = self
        browser.setFocus(false)
        browser.close(force: true)
    }

    func focus() {
        wantsFocus = true
        guard !isAddressFieldFocused else {
            browser?.setFocus(false)
            return
        }
        browser?.setFocus(true)
    }

    func unfocus() {
        wantsFocus = false
        isAddressFieldFocused = false
        browser?.setFocus(false)
    }

    func setVisibleInUI(_ visible: Bool) {
        guard isVisibleInUI != visible else { return }
        isVisibleInUI = visible
        hostView.isHidden = !visible
        browser?.setHidden(!visible)
        if visible {
            browser?.setFocus(wantsFocus && !isAddressFieldFocused)
        } else {
            browser?.setFocus(false)
        }
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }

    func setAddressFieldFocused(_ isFocused: Bool) {
        isAddressFieldFocused = isFocused
        if isFocused {
            browser?.setFocus(false)
        }
    }

    var omnibarDisplayURL: URL? {
        preferredURLStringForOmnibar().flatMap(URL.init(string:))
    }

    var pageTitle: String { title }

    var isOmnibarVisible: Bool { true }

    var isContentBlankForOmnibar: Bool {
        preferredURLStringForOmnibar() == nil
    }

    var isContentNavigationInFlight: Bool { isLoading }

    var omnibarHostWindow: NSWindow? { containerView.window }

    func beginSuppressContentFocusForAddressBar() {
        setAddressFieldFocused(true)
    }

    func endSuppressContentFocusForAddressBar() {
        setAddressFieldFocused(false)
    }

    func shouldSuppressContentFocus() -> Bool {
        isAddressFieldFocused
    }

    func shouldSuppressOmnibarAutofocus() -> Bool { false }

    func noteAddressBarFocused() {
        setAddressFieldFocused(true)
    }

    @discardableResult
    func requestAddressBarFocus(
        selectionIntent: BrowserAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
    ) -> UUID {
        if let pendingAddressBarFocusRequestId {
            if selectionIntent == .selectAll {
                pendingAddressBarFocusSelectionIntent = .selectAll
            }
            return pendingAddressBarFocusRequestId
        }
        let requestID = UUID()
        pendingAddressBarFocusSelectionIntent = selectionIntent
        pendingAddressBarFocusRequestId = requestID
        beginSuppressContentFocusForAddressBar()
        return requestID
    }

    func acknowledgeAddressBarFocusRequest(_ requestID: UUID) {
        guard pendingAddressBarFocusRequestId == requestID else { return }
        pendingAddressBarFocusRequestId = nil
        pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
    }

    func performAddressBarExitFocusHandoff(
        onComplete: @escaping @MainActor (Bool) -> Void
    ) {
        setAddressFieldFocused(false)
        guard let browser else {
            onComplete(false)
            return
        }
        browser.setFocus(true)
        onComplete(true)
    }

    func browser(_ browser: CEFBrowser, didUpdateURL url: String) {
        guard browser === self.browser else { return }
        currentURL = url
        lastEmbeddedURL = url
    }

    func browser(_ browser: CEFBrowser, didUpdateTitle title: String) {
        guard browser === self.browser else { return }
        self.title = title
    }

    func browser(
        _ browser: CEFBrowser,
        didUpdateLoadingState isLoading: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        guard browser === self.browser else { return }
        applyLoadingState(
            isLoading: isLoading,
            canGoBack: canGoBack,
            canGoForward: canGoForward
        )
    }

    func browserDidClose(_ browser: CEFBrowser) {
        guard browser === self.browser else { return }
        self.browser = nil
        if !isClosing {
            hasStarted = false
        }
        pendingNavigationURL = nil
        isLoading = false
        canGoBack = false
        canGoForward = false
        closingRetain = nil
    }

    private func createBrowser(url: String) {
        guard !isClosing else { return }
        guard let profileResolution = resolveCEFProfile() else {
            hasStarted = false
            pendingNavigationURL = nil
            cefBrowserLogger.error("CEF profile creation failed")
            return
        }
        isCreatingBrowser = true
        CEFBrowser.create(
            in: containerView,
            frame: containerView.bounds,
            url: url,
            profile: profileResolution.profile,
            delegate: self
        ) { [weak self] browser in
            guard let self else {
                browser?.close(force: true)
                return
            }

            self.isCreatingBrowser = false
            guard let browser else {
                self.hasStarted = false
                self.pendingNavigationURL = nil
                self.closingRetain = nil
                cefBrowserLogger.error("browser creation failed")
                return
            }

            self.browser = browser
            browser.setHidden(!self.isVisibleInUI)
            if self.isClosing {
                self.closingRetain = self
                browser.close(force: true)
                return
            }

            if let pendingNavigationURL = self.pendingNavigationURL {
                self.pendingNavigationURL = nil
                if pendingNavigationURL != url {
                    browser.load(url: pendingNavigationURL)
                }
            }
            browser.setFocus(self.isVisibleInUI && self.wantsFocus && !self.isAddressFieldFocused)
        }
    }

    func applyLoadingState(
        isLoading: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        let didFinishLoading = self.isLoading && !isLoading
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        if didFinishLoading {
            historyStore.recordVisit(url: URL(string: currentURL), title: title)
        }
    }

    private func openChromeStyleWindow(url: String) {
        guard CEFRuntimeSupport.isRuntimeBundled else {
            cefBrowserLogger.error("CEF runtime is not bundled")
            return
        }

        do {
            try CEFRuntimeSupport.startIfNeeded()
        } catch {
            cefBrowserLogger.error("CEF initialization failed: \(String(describing: error), privacy: .private)")
            return
        }

        CEFApp.shared.onContextInitialized { [weak self] in
            guard let self, let profileResolution = self.resolveCEFProfile() else {
                cefBrowserLogger.error("CEF profile creation failed")
                return
            }
            CEFBrowser.openChromeStyleWindow(url: url, profile: profileResolution.profile)
        }
    }

    /// The built-in browser profile intentionally uses CEF's global request
    /// context. Every named cmux profile gets a stable UUID-backed context so
    /// restored panes retain the same cookies and storage across launches.
    private func resolveCEFProfile() -> CEFProfileResolution? {
        if profileID == BrowserProfileStore.shared.builtInDefaultProfileID {
            return CEFProfileResolution(profile: nil)
        }
        if let cefProfile {
            return CEFProfileResolution(profile: cefProfile)
        }
        guard let profile = CEFProfile(name: cefProfileName) else { return nil }
        cefProfile = profile
        return CEFProfileResolution(profile: profile)
    }

    private static func normalizedURLString(_ rawURL: String) -> String? {
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }

        let lowercasedURL = trimmedURL.lowercased()
        let hasHierarchicalScheme = trimmedURL.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#,
            options: .regularExpression
        ) != nil
        let hasSupportedOpaqueScheme = ["about:", "chrome:", "data:", "javascript:", "mailto:"].contains {
            lowercasedURL.hasPrefix($0)
        }

        if hasHierarchicalScheme || hasSupportedOpaqueScheme {
            return trimmedURL
        }
        return "https://\(trimmedURL)"
    }
}
