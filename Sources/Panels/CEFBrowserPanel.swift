import AppKit
import CEFKit
import Combine
import Foundation

/// A first-pass Chromium Embedded Framework browser hosted as a cmux panel.
/// CEFKit guarantees that delegate callbacks arrive on the main thread; its
/// delegate protocol predates actor annotations, so the conformance is imported
/// with `@preconcurrency` while this panel remains main-actor isolated.
@MainActor
final class CEFBrowserPanel: Panel, ObservableObject, @preconcurrency CEFBrowserDelegate {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .cefBrowser
    let containerView: CEFBrowserContainerView

    @Published var currentURL: String
    @Published private(set) var title: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    private(set) var browser: CEFBrowser?
    private var hasStarted = false
    private var isCreatingBrowser = false
    private var isClosing = false
    private var wantsFocus = false
    private var isAddressFieldFocused = false
    private var pendingNavigationURL: String?
    private var lastEmbeddedURL: String

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

    init(id: UUID = UUID(), initialURL: String = "about:blank") {
        self.id = id
        self.currentURL = initialURL
        self.lastEmbeddedURL = initialURL
        self.containerView = CEFBrowserContainerView(frame: .zero)
    }

    /// Starts the embedded browser after the process-wide CEF context is ready.
    func start(url rawURL: String) {
        guard !hasStarted, !isClosing else { return }
        guard CEFRuntimeSupport.isRuntimeBundled else {
            NSLog("CEFBrowserPanel: CEF runtime is not bundled")
            return
        }

        do {
            try CEFRuntimeSupport.startIfNeeded()
        } catch {
            NSLog("CEFBrowserPanel: CEF initialization failed: %@", String(describing: error))
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

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }

    func setAddressFieldFocused(_ isFocused: Bool) {
        isAddressFieldFocused = isFocused
        if isFocused {
            browser?.setFocus(false)
        }
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
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
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
        isCreatingBrowser = true
        CEFBrowser.create(
            in: containerView,
            frame: containerView.bounds,
            url: url,
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
                NSLog("CEFBrowserPanel: browser creation failed")
                return
            }

            self.browser = browser
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
            browser.setFocus(self.wantsFocus && !self.isAddressFieldFocused)
        }
    }

    private func openChromeStyleWindow(url: String) {
        guard CEFRuntimeSupport.isRuntimeBundled else {
            NSLog("CEFBrowserPanel: CEF runtime is not bundled")
            return
        }

        do {
            try CEFRuntimeSupport.startIfNeeded()
        } catch {
            NSLog("CEFBrowserPanel: CEF initialization failed: %@", String(describing: error))
            return
        }

        CEFApp.shared.onContextInitialized {
            CEFBrowser.openChromeStyleWindow(url: url)
        }
    }

    private static func normalizedURLString(_ rawURL: String) -> String? {
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }

        let lowercasedURL = trimmedURL.lowercased()
        let hasHierarchicalScheme = trimmedURL.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#,
            options: .regularExpression
        ) != nil
        let hasSupportedOpaqueScheme = ["about:", "data:", "javascript:", "mailto:"].contains {
            lowercasedURL.hasPrefix($0)
        }

        if hasHierarchicalScheme || hasSupportedOpaqueScheme {
            return trimmedURL
        }
        return "https://\(trimmedURL)"
    }
}
