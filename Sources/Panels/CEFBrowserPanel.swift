import AppKit
import Combine
import Foundation

#if canImport(CMUXCEF)
import CMUXCEF
#endif

/// Browser pane backed by the Chromium Embedded Framework (CEF) engine.
///
/// This is the experimental parallel to ``BrowserPanel``, opt-in via the
/// **Debug → Browser Engine → CEF** menu (see
/// ``BrowserEngineKind/cef``).
///
/// `CEFBrowserPanel` deliberately mirrors the public surface of
/// ``BrowserPanel`` only as far as the ``Panel`` protocol requires; the
/// extensive WKWebView-specific behaviour (popups, find-in-page,
/// `WKWebsiteDataStore`, telemetry hooks, etc.) is intentionally **not**
/// duplicated here. WKWebView remains the default and the more
/// feature-complete path. CEF parity work happens in follow-up PRs.
///
/// ## Compile-time behaviour
///
/// The CEF engine is gated on `#if canImport(CMUXCEF)`. Until the
/// Xcode project links the `CEF/` Swift package (see
/// `CEF/INTEGRATION.md`), this file compiles into a stub that throws a
/// localized error at construction so the workspace can fall back to
/// `BrowserPanel`. After the package is wired, the same source compiles
/// into a fully-functional Panel implementation.
@MainActor
final class CEFBrowserPanel: BrowserEngineBackedPanel {

    // MARK: Panel protocol — engine-agnostic metadata

    let id: UUID = UUID()
    let panelType: PanelType = .browser
    @Published private(set) var displayTitle: String
    @Published private(set) var displayIcon: String? = "globe"

    // MARK: BrowserEngineBackedPanel — shape shared with BrowserPanel

    /// Workspace this pane belongs to. Mirrors ``BrowserPanel/workspaceId``.
    let workspaceId: UUID

    /// cmux's user-facing profile identifier. Each cmux profile maps
    /// 1:1 onto a `CefRequestContext` (= Chromium profile) so cookies,
    /// `chrome.storage`, login state, and extension state are isolated
    /// across profiles, just like the WKWebView path's
    /// `WKWebsiteDataStore` isolation.
    @Published private(set) var profileID: UUID

    /// True while the CEF browser is in the middle of a navigation.
    /// Mirrors ``BrowserPanel/isLoading`` so the tab strip's loading
    /// indicator works the same in both engines.
    @Published private(set) var isLoading: Bool = false

    /// Current main-frame URL, surfaced to the lightweight CEF toolbar.
    @Published private(set) var currentURL: URL?

    /// Browser history availability, surfaced to the lightweight CEF toolbar.
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false

    /// Last main-frame load error, if any. Kept out of the primary pane UI
    /// for now; debug builds can inspect it through the panel object.
    @Published private(set) var loadErrorDescription: String?

    /// URL the pane was created with. Re-loaded after a renderer
    /// crash; navigated to immediately on ``focus()`` if the underlying
    /// CEF browser isn't open yet.
    private(set) var initialURL: URL?

    // MARK: CEF engine handle

    #if canImport(CMUXCEF)
    /// The live CEF browser. Nil before ``activate()`` has been called.
    /// Held strongly; `close()` releases it.
    private var browser: CMUXCEF.CEFBrowser?
    #endif
    private let renderInitialNavigation: Bool

    /// Bumped whenever the underlying CEF browser is (re)created so SwiftUI
    /// re-fetches `embeddableView` via `CEFBrowserPanelView`. SwiftUI keys
    /// off this Int rather than the strong reference to keep value-type
    /// semantics in the panel API.
    @Published private(set) var activationRevision: Int = 0

    // MARK: Construction

    /// Mirrors the BrowserPanel initializer signature closely enough
    /// that ``Workspace/newBrowserSplit(...)`` can swap engines with a
    /// minimal branch. Fields that don't apply to CEF (proxy endpoint,
    /// remote website data store, telemetry flags) are accepted and
    /// stored for later, not yet wired through.
    init(
        workspaceId: UUID,
        profileID: UUID,
        initialURL: URL?,
        renderInitialNavigation: Bool = true,
        proxyEndpoint: BrowserProxyEndpoint? = nil,
        isRemoteWorkspace: Bool = false,
        remoteWebsiteDataStoreIdentifier: UUID? = nil
    ) {
        self.workspaceId = workspaceId
        self.profileID = profileID
        self.initialURL = initialURL
        self.currentURL = initialURL
        self.renderInitialNavigation = renderInitialNavigation
        self.displayTitle = initialURL?.host ?? String(
            localized: "browser.tab.untitled",
            defaultValue: "New Tab")
        // proxy / remote-workspace knobs are accepted now and tracked
        // by follow-up PRs; CEF needs a different transport setup than
        // WKWebView's WKWebsiteDataStore.
        _ = proxyEndpoint
        _ = isRemoteWorkspace
        _ = remoteWebsiteDataStoreIdentifier
    }

    // MARK: Lifecycle

    /// Lazily creates the underlying CEF browser instance and starts
    /// the engine if it hasn't been started yet. cmux calls this when
    /// the panel becomes visible.
    /// Sibling-overlay path: create the CEF browser via Chrome runtime
    /// (`makeEmbeddableBrowser`), then return the extracted NSView so
    /// cmux can mount it into a `CEFOverlayHost` overlay — outside the
    /// SwiftUI hosting chain — where Chromium's CARemoteLayer compositor
    /// can actually paint pixels.
    func activate() throws {
        #if canImport(CMUXCEF)
        guard browser == nil else {
            #if DEBUG
            cmuxDebugLog("cef.panel.activate.skip alreadyActive panel=\(id.uuidString.prefix(5))")
            #endif
            return
        }
        let engine = CMUXCEF.CEFEngine.shared
        #if DEBUG
        cmuxDebugLog("cef.panel.activate.begin panel=\(id.uuidString.prefix(5)) engineRunning=\(engine.isRunning)")
        #endif
        if !engine.isRunning {
            // The user toggled to CEF mid-session, after the app launched
            // with WKWebView and skipped CEF startup. Lazily boot the
            // engine now so the pane can render without a full app
            // restart. Idempotent: `startCEFEngineIfNeeded()` re-checks
            // `isRunning` internally.
            //
            // Use the file-scope free function rather than
            // `NSApp.delegate as? AppDelegate`: under SwiftUI's
            // `NSApplicationDelegateAdaptor` the runtime delegate cast
            // fails and silently swallows the lazy-start.
            startCEFEngineIfNeeded()
            if !engine.isRunning {
                throw CEFBrowserPanelError.engineNotStarted
            }
        }
        let profile = CMUXCEF.CEFProfileRegistry.shared.profile(named: profileID.uuidString)
        let url = renderInitialNavigation
            ? (initialURL ?? URL(string: "chrome://extensions/")!)
            : URL(string: "about:blank")!
        let createdBrowser = try engine.makeEmbeddableBrowser(profile: profile, initialURL: url)
        createdBrowser.delegate = self
        browser = createdBrowser
        if renderInitialNavigation {
            refreshNavigationState(from: createdBrowser, fallbackURL: url)
        } else {
            canGoBack = false
            canGoForward = false
            currentURL = initialURL
        }
        activationRevision &+= 1
        #if DEBUG
        let viewDesc = createdBrowser.embeddableView.map { "\($0)" } ?? "nil"
        cmuxDebugLog("cef.panel.activate.done panel=\(id.uuidString.prefix(5)) view=\(viewDesc)")
        #endif

        #else
        throw CEFBrowserPanelError.notLinked
        #endif
    }

    /// Returns the live AppKit view that hosts CEF's rendering surface,
    /// ready to be added to the cmux pane's view hierarchy. Nil before
    /// ``activate()`` has succeeded.
    var embeddableView: NSView? {
        #if canImport(CMUXCEF)
        return browser?.embeddableView
        #else
        return nil
        #endif
    }

    /// Tell the underlying CEF browser about the current screen rectangle.
    /// The current Path B bridge keeps CEF's own NSWindow parked offscreen
    /// and renders through the extracted AppKit view, so this is a no-op
    /// until mouse-coordinate syncing is reintroduced.
    func syncRenderFrame(toScreen rect: NSRect) {
        #if canImport(CMUXCEF)
        browser?.syncRenderFrame(toScreen: rect)
        #endif
    }

    /// Attach the CEF browser's child-window overlay to the cmux host
    /// `NSWindow`. Called by `CEFOverlayProbeView.viewDidMoveToWindow`.
    func attachOverlay(toHost window: NSWindow) {
        #if canImport(CMUXCEF)
        browser?.attach(toHost: window)
        #endif
    }

    /// Tell Chromium the embedded view has been re-parented / sized so it
    /// pushes a fresh render layer at the current view dimensions.
    func notifyEmbedHostResized() {
        #if canImport(CMUXCEF)
        browser?.notifyEmbedHostResizedAndShown()
        #endif
    }

    // MARK: Navigation controls

    var addressBarDisplayString: String {
        currentURL?.absoluteString
            ?? initialURL?.absoluteString
            ?? "https://google.com"
    }

    func load(_ url: URL) {
        currentURL = url
        displayTitle = url.host ?? url.absoluteString
        loadErrorDescription = nil
        #if canImport(CMUXCEF)
        browser?.load(url)
        if let browser {
            refreshNavigationState(from: browser, fallbackURL: url)
        }
        #endif
    }

    func goBack() {
        #if canImport(CMUXCEF)
        browser?.goBack()
        #endif
    }

    func goForward() {
        #if canImport(CMUXCEF)
        browser?.goForward()
        #endif
    }

    func reload() {
        #if canImport(CMUXCEF)
        browser?.reload()
        #endif
    }

    func stopLoading() {
        #if canImport(CMUXCEF)
        browser?.stopLoading()
        #endif
    }

    func showDevTools() {
        #if canImport(CMUXCEF)
        browser?.showDevTools()
        #endif
    }

    // MARK: Panel conformance

    var isDirty: Bool { false }

    func close() {
        #if canImport(CMUXCEF)
        detachEmbeddableViewFromAppKit()
        browser?.close()
        browser = nil
        activationRevision &+= 1
        #endif
    }

    func focus() {
        // CEF takes focus via the embeddableView's first-responder
        // chain. cmux's window code already calls
        // `makeFirstResponder(panel.webView)` for browser panes; once
        // CEFBrowserPanelView is wired we route the same signal.
        guard let view = embeddableView, let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    func unfocus() {
        // No-op for v1. CEF resigns first responder via AppKit's
        // standard responder chain when another view becomes key.
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        // Flash is presentation-level state owned by the workspace;
        // engine-agnostic so we just no-op here (matches MarkdownPanel
        // / FilePreviewPanel behaviour).
        _ = reason
    }

    #if canImport(CMUXCEF)
    private func detachEmbeddableViewFromAppKit() {
        guard let view = browser?.embeddableView else { return }
        if let window = view.window,
           let firstResponderView = window.firstResponder as? NSView,
           firstResponderView === view || firstResponderView.isDescendant(of: view)
        {
            window.makeFirstResponder(nil)
        }
        view.removeFromSuperview()
        #if DEBUG
        cmuxDebugLog("cef.panel.detachView panel=\(id.uuidString.prefix(5))")
        #endif
    }

    private func refreshNavigationState(
        from browser: CMUXCEF.CEFBrowser,
        fallbackURL: URL? = nil
    ) {
        isLoading = browser.isLoading
        canGoBack = browser.canGoBack
        canGoForward = browser.canGoForward
        currentURL = browser.currentURL ?? fallbackURL ?? currentURL
        if let title = browser.currentTitle, !title.isEmpty {
            displayTitle = title
        } else if let url = currentURL {
            displayTitle = url.host ?? url.absoluteString
        }
    }
    #endif
}

#if canImport(CMUXCEF)
extension CEFBrowserPanel: CMUXCEF.CEFBrowserDelegate {
    func cefBrowserDidStartLoading(_ browser: CMUXCEF.CEFBrowser) {
        loadErrorDescription = nil
        refreshNavigationState(from: browser)
        isLoading = true
        #if DEBUG
        let urlLength = browser.currentURL?.absoluteString.utf8.count ?? 0
        cmuxDebugLog("cef.panel.didStartLoading panel=\(id.uuidString.prefix(5)) urlLength=\(urlLength)")
        #endif
    }

    func cefBrowserDidFinishLoading(_ browser: CMUXCEF.CEFBrowser) {
        refreshNavigationState(from: browser)
        isLoading = false
        #if DEBUG
        let urlLength = browser.currentURL?.absoluteString.utf8.count ?? 0
        let titleLength = browser.currentTitle?.utf8.count ?? 0
        cmuxDebugLog("cef.panel.didFinishLoading panel=\(id.uuidString.prefix(5)) urlLength=\(urlLength) titleLength=\(titleLength)")
        #endif
    }

    func cefBrowser(_ browser: CMUXCEF.CEFBrowser, didChangeTitle title: String) {
        displayTitle = title.isEmpty
            ? (currentURL?.host ?? addressBarDisplayString)
            : title
        #if DEBUG
        cmuxDebugLog("cef.panel.didChangeTitle panel=\(id.uuidString.prefix(5)) titleLength=\(title.utf8.count)")
        #endif
    }

    func cefBrowser(_ browser: CMUXCEF.CEFBrowser, didChangeURL url: URL) {
        currentURL = url
        refreshNavigationState(from: browser, fallbackURL: url)
        #if DEBUG
        cmuxDebugLog("cef.panel.didChangeURL panel=\(id.uuidString.prefix(5)) urlLength=\(url.absoluteString.utf8.count)")
        #endif
    }

    func cefBrowser(_ browser: CMUXCEF.CEFBrowser, didFailLoad error: Error) {
        loadErrorDescription = error.localizedDescription
        refreshNavigationState(from: browser)
        isLoading = false
        #if DEBUG
        cmuxDebugLog("cef.panel.didFailLoad panel=\(id.uuidString.prefix(5)) errorType=\(String(describing: type(of: error)))")
        #endif
    }
}
#endif

// MARK: - Errors

enum CEFBrowserPanelError: LocalizedError {
    /// The cmux app delegate has not invoked
    /// `CEFEngine.shared.start(config:)`. The flag was switched on
    /// without the CEF infrastructure being initialized.
    case engineNotStarted

    /// The `CEF/` Swift package isn't linked into this build of cmux.
    /// Toggling the engine flag had no effect — see
    /// `CEF/INTEGRATION.md` for the manual Xcode wire-up.
    case notLinked

    public var errorDescription: String? {
        switch self {
        case .engineNotStarted:
            return String(
                localized: "cefBrowserPanel.engineNotStarted",
                defaultValue: "The CEF browser engine has not been initialized.")
        case .notLinked:
            return String(
                localized: "cefBrowserPanel.notLinked",
                defaultValue: "The CEF browser engine is not available in this build of cmux.")
        }
    }
}
