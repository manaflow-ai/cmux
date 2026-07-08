import Foundation
import CmuxCore
import CmuxBrowser
import CmuxNotifications
import CmuxSettings
import Combine
import CmuxAppKitSupportUI
import WebKit
import AppKit
import Bonsplit
import CmuxTerminalCore
import CmuxWorkspaces
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
import CmuxTerminal
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif

private struct BrowserFocusModePlainEscapeEventFingerprint: Equatable {
    let type: NSEvent.EventType
    let timestamp: TimeInterval
    let windowNumber: Int
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags.RawValue

    init(_ event: NSEvent) {
        self.type = event.type
        self.timestamp = event.timestamp
        self.windowNumber = event.windowNumber
        self.keyCode = event.keyCode
        self.modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
            .rawValue
    }
}

enum GhosttyBackgroundTheme {
    static func clampedOpacity(_ opacity: Double) -> CGFloat {
        WindowAppearanceSnapshot.clampedOpacity(opacity)
    }

    static func color(backgroundColor: NSColor, opacity: Double) -> NSColor {
        WindowAppearanceSnapshot.compositedTerminalColor(
            backgroundColor: backgroundColor,
            opacity: opacity
        )
    }

    static func color(
        from notification: Notification?,
        fallbackColor: NSColor,
        fallbackOpacity: Double
    ) -> NSColor {
        let userInfo = notification?.userInfo
        let backgroundColor =
            (userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)
            ?? fallbackColor

        let opacity: Double
        if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? Double {
            opacity = value
        } else if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? NSNumber {
            opacity = value.doubleValue
        } else {
            opacity = fallbackOpacity
        }

        return color(backgroundColor: backgroundColor, opacity: opacity)
    }

    static func color(from notification: Notification?) -> NSColor {
        color(
            from: notification,
            fallbackColor: GhosttyApp.shared.defaultBackgroundColor,
            fallbackOpacity: GhosttyApp.shared.defaultBackgroundOpacity
        )
    }

    static func currentColor() -> NSColor {
        color(
            backgroundColor: GhosttyApp.shared.defaultBackgroundColor,
            opacity: GhosttyApp.shared.defaultBackgroundOpacity
        )
    }
}

// `BrowserThemeSettings` (theme-mode UserDefaults keys, default mode, the
// `mode(for:)`/`mode(defaults:)` resolution + legacy migration, and
// `apply(_:to:)`) now lives in the `CmuxBrowser` package (imported above); the
// call sites reference it unqualified through that import.

// `BrowserImportHintVariant`, `BrowserImportHintBlankTabPlacement`,
// `BrowserImportHintSettingsStatus`, `BrowserImportHintPresentation`, and the
// `BrowserImportHintSettings` store now live in the `CmuxBrowser` package
// (imported above); the call sites reference them unqualified through that
// import.

// `BrowserProfileDefinition` and `BrowserProfileClearOutcome` now live in the
// `CmuxBrowser` package (imported above); the call sites reference them
// unqualified through that import.

// `BrowserProfileStore` (the profile-selection ObservableObject facade) plus its
// history/website-data-store/file-remover seam adapters now live in the
// `CmuxBrowser` package (imported above). The process-wide singleton stays here
// in the composition root so its localized default-profile display name resolves
// `String(localized:)` against the app bundle's `.xcstrings`.
extension BrowserProfileStore {
    static let shared = BrowserProfileStore(
        defaultProfileDisplayName: String(localized: "browser.profile.default", defaultValue: "Default")
    )
}

// The browser link/availability/insecure-HTTP policy settings moved to the
// CmuxBrowser package (Settings/). These typealiases keep the app-target
// spellings resolving for the many call sites that do not import CmuxBrowser.
typealias BrowserLinkOpenSettings = CmuxBrowser.BrowserLinkOpenSettings
typealias BrowserAvailabilitySettings = CmuxBrowser.BrowserAvailabilitySettings
typealias BrowserInsecureHTTPSettings = CmuxBrowser.BrowserInsecureHTTPSettings

// The insecure-HTTP navigation-policy decisions (block decision + one-time
// bypass) moved to CmuxBrowser as static methods on BrowserInsecureHTTPSettings
// (Settings/BrowserInsecureHTTPSettings+NavigationPolicy.swift).

// `browserShouldPersistInsecureHTTPAllowlistSelection` (the allowlist-persist
// modal-response decision) now lives in the `CmuxBrowser` package as the static
// `BrowserInsecureHTTPSettings.shouldPersistAllowlistSelection(response:suppressionEnabled:)`
// (Settings/BrowserInsecureHTTPSettings+NavigationPolicy.swift).

/// Mirrors the opener's WebKit browsing context for popup windows.
struct BrowserPopupBrowserContext {
    let websiteDataStore: WKWebsiteDataStore
}

func browserInteractiveModalHostWindow(_ window: NSWindow?) -> NSWindow? {
    guard let window else { return nil }
    guard window.isVisible else { return nil }
    guard window.alphaValue > 0 else { return nil }
    guard !window.ignoresMouseEvents else { return nil }
    guard !window.isExcludedFromWindowsMenu else { return nil }
    return window
}

func browserInteractiveModalHostWindow(for webView: WKWebView) -> NSWindow? {
    browserInteractiveModalHostWindow(webView.window)
}

typealias BrowserAlertPresenter = (
    _ alert: NSAlert,
    _ webView: WKWebView,
    _ completion: @escaping (NSApplication.ModalResponse) -> Void,
    _ cancel: @escaping () -> Void
) -> Void

func browserPresentAlert(
    _ alert: NSAlert,
    in webView: WKWebView,
    completion: @escaping (NSApplication.ModalResponse) -> Void,
    cancel: @escaping () -> Void = {}
) {
    _ = cancel
    if let window = browserInteractiveModalHostWindow(for: webView) {
        alert.beginSheetModal(for: window, completionHandler: completion)
        return
    }
    completion(alert.runModal())
}

@discardableResult
private func browserOpenExternalNavigationURL(
    _ url: URL,
    source: String,
    webView: WKWebView,
    presentAlert: @escaping BrowserAlertPresenter = browserPresentAlert
) -> Bool {
    let opened = NSWorkspace.shared.open(url)
    if !opened {
        BrowserExternalNavigationPresenter(presentAlert: presentAlert)
            .presentFailure(for: url, in: webView)
    }
#if DEBUG
    cmuxDebugLog(
        "browser.navigation.external source=\(source) opened=\(opened ? 1 : 0) " +
        "url=\(browserNavigationDebugURL(url))"
    )
#endif
    return opened
}

@discardableResult
func browserHandleExternalNavigation(
    _ url: URL,
    source: String,
    webView: WKWebView,
    loadFallbackRequest: (URLRequest) -> Void,
    presentAlert: @escaping BrowserAlertPresenter = browserPresentAlert
) -> Bool {
    guard let action = BrowserExternalNavigationAction.resolve(for: url) else { return false }

    switch action {
    case let .browserFallback(fallbackURL):
        let request = URLRequest(url: fallbackURL)
        loadFallbackRequest(request)
#if DEBUG
        cmuxDebugLog(
            "browser.navigation.external source=\(source) opened=1 fallback=1 " +
            "fallbackURL=\(browserNavigationDebugURL(fallbackURL)) url=\(browserNavigationDebugURL(url))"
        )
#endif
        return true

    case let .promptToOpenApp(externalURL):
        BrowserExternalNavigationPresenter(presentAlert: presentAlert).presentPrompt(
            for: externalURL,
            in: webView,
            completion: { shouldOpenApp in
                guard shouldOpenApp else {
#if DEBUG
                    cmuxDebugLog(
                        "browser.navigation.external source=\(source) opened=0 prompt=1 allowed=0 " +
                        "url=\(browserNavigationDebugURL(externalURL))"
                    )
#endif
                    return
                }
                browserOpenExternalNavigationURL(
                    externalURL,
                    source: source,
                    webView: webView,
                    presentAlert: presentAlert
                )
            }
        )
        return true
    }
}

func normalizedBrowserHistoryNamespace(bundleIdentifier: String) -> String {
    BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: bundleIdentifier)
}

/// BrowserPanel provides a WKWebView-based browser panel.
/// Each browser panel can recover from WebContent crashes by replacing its web view.
// The insecure-HTTP navigation intent + the navigation-intent coordinator/host
// seam moved to CmuxBrowser (Navigation/). This typealias keeps the app-target
// spelling resolving for the delegate closure types that do not import it.
typealias BrowserInsecureHTTPNavigationIntent = CmuxBrowser.BrowserInsecureHTTPNavigationIntent

// `BrowserWebViewLifecycleState` (the pure web-view lifecycle-phase enum) now
// lives in the `CmuxBrowser` package (imported above); the call sites reference
// it unqualified through that import.

/// Observable state for browser find-in-page. Mirrors `TerminalSurface.SearchState`.
@MainActor
final class BrowserSearchState: ObservableObject {
    @Published var needle: String
    @Published var selected: UInt?
    @Published var total: UInt?

    init(needle: String = "") {
        self.needle = needle
    }
}

final class BrowserPortalAnchorView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class BrowserPanel: Panel, ObservableObject, BrowserNavigationHosting, BrowserSessionHistoryHosting, BrowserFaviconHosting, BrowserZoomHosting, BrowserDownloadActivityHosting, BrowserFindHosting {
    /// Popup windows owned by this panel (for lifecycle cleanup)
    private var popupControllers: [BrowserPopupWindowController] = []

    static let telemetryHookBootstrapScriptSource = """
    (() => {
      if (window.__cmuxHooksInstalled) return true;
      window.__cmuxHooksInstalled = true;

      window.__cmuxConsoleLog = window.__cmuxConsoleLog || [];
      const __pushConsole = (level, args) => {
        try {
          const text = Array.from(args || []).map((x) => {
            if (typeof x === 'string') return x;
            try { return JSON.stringify(x); } catch (_) { return String(x); }
          }).join(' ');
          window.__cmuxConsoleLog.push({ level, text, timestamp_ms: Date.now() });
          if (window.__cmuxConsoleLog.length > 512) {
            window.__cmuxConsoleLog.splice(0, window.__cmuxConsoleLog.length - 512);
          }
        } catch (_) {}
      };

      const methods = ['log', 'info', 'warn', 'error', 'debug'];
      for (const m of methods) {
        const orig = (window.console && window.console[m]) ? window.console[m].bind(window.console) : null;
        window.console[m] = function(...args) {
          __pushConsole(m, args);
          if (orig) return orig(...args);
        };
      }

      window.__cmuxErrorLog = window.__cmuxErrorLog || [];
      window.addEventListener('error', (ev) => {
        try {
          const message = String((ev && ev.message) || '');
          const source = String((ev && ev.filename) || '');
          const line = Number((ev && ev.lineno) || 0);
          const col = Number((ev && ev.colno) || 0);
          window.__cmuxErrorLog.push({ message, source, line, column: col, timestamp_ms: Date.now() });
          if (window.__cmuxErrorLog.length > 512) {
            window.__cmuxErrorLog.splice(0, window.__cmuxErrorLog.length - 512);
          }
        } catch (_) {}
      });
      window.addEventListener('unhandledrejection', (ev) => {
        try {
          const reason = ev && ev.reason;
          const message = typeof reason === 'string' ? reason : (reason && reason.message ? String(reason.message) : String(reason));
          window.__cmuxErrorLog.push({ message, source: 'unhandledrejection', line: 0, column: 0, timestamp_ms: Date.now() });
          if (window.__cmuxErrorLog.length > 512) {
            window.__cmuxErrorLog.splice(0, window.__cmuxErrorLog.length - 512);
          }
        } catch (_) {}
      });

      return true;
    })()
    """

    static let dialogTelemetryHookBootstrapScriptSource = """
    (() => {
      if (window.__cmuxDialogHooksInstalled) return true;
      window.__cmuxDialogHooksInstalled = true;

      window.__cmuxDialogQueue = window.__cmuxDialogQueue || [];
      window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
      const __pushDialog = (type, message, defaultText) => {
        window.__cmuxDialogQueue.push({
          type,
          message: String(message || ''),
          default_text: defaultText == null ? null : String(defaultText),
          timestamp_ms: Date.now()
        });
        if (window.__cmuxDialogQueue.length > 128) {
          window.__cmuxDialogQueue.splice(0, window.__cmuxDialogQueue.length - 128);
        }
      };

      window.alert = function(message) {
        __pushDialog('alert', message, null);
      };
      window.confirm = function(message) {
        __pushDialog('confirm', message, null);
        return !!window.__cmuxDialogDefaults.confirm;
      };
      window.prompt = function(message, defaultValue) {
        __pushDialog('prompt', message, defaultValue == null ? null : defaultValue);
        const v = window.__cmuxDialogDefaults.prompt;
        if (v === null || v === undefined) {
          return defaultValue == null ? '' : String(defaultValue);
        }
        return String(v);
      };

      return true;
    })()
    """

    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .browser

    /// The workspace ID this panel belongs to
    private(set) var workspaceId: UUID

    @Published private(set) var profileID: UUID
    @Published private(set) var historyStore: BrowserHistoryStore

    /// The underlying web view
    private(set) var webView: WKWebView
    private var websiteDataStore: WKWebsiteDataStore
    var webViewDidRequestClose: (() -> Void)?

    /// Monotonic identity for the current WKWebView instance.
    /// Incremented whenever we replace the underlying WKWebView after a process crash.
    @Published private(set) var webViewInstanceID: UUID = UUID()
    private(set) var hasRecoverableWebContentTermination = false {
        willSet {
            if newValue != hasRecoverableWebContentTermination {
                objectWillChange.send()
            }
        }
    }
    private var pendingWebContentRecoveryURL: URL?

    /// Prevent the omnibar from auto-focusing for a short window after explicit programmatic focus.
    /// This avoids races where SwiftUI focus state steals first responder back from WebKit.
    private var suppressOmnibarAutofocusUntil: Date?

    /// Prevent forcing web-view focus when another UI path requested omnibar focus.
    /// Used to keep omnibar text-field focus from being immediately stolen by panel focus.
    private var suppressWebViewFocusUntil: Date?
    private var suppressWebViewFocusForAddressBar: Bool = false
    private let blankURLString = "about:blank"

    /// Owns the address-bar page-focus capture/restore subsystem.
    ///
    /// The repository (in `CmuxBrowser`) runs the capture/restore scripts
    /// through ``BrowserOmnibarPageFocusAdapter``, which reaches back to this
    /// panel's current `webView` weakly so the panel and repository do not retain
    /// each other.
    private lazy var omnibarPageFocusRepository = BrowserOmnibarPageFocusRepository(
        evaluator: BrowserOmnibarPageFocusAdapter(panel: self),
        logSink: Self.omnibarPageFocusLogSink
    )

    /// Published URL being displayed
    @Published private(set) var currentURL: URL? {
        didSet {
            guard oldValue != currentURL else { return }
            applyConfiguredWebViewBackground()
        }
    }

    /// Whether the browser panel should render its WKWebView in the content area.
    /// New browser tabs stay in an empty "new tab" state until first navigation.
    @Published private(set) var shouldRenderWebView: Bool = false {
        didSet {
            if oldValue != shouldRenderWebView {
                refreshWebViewLifecycleState()
                applyConfiguredWebViewBackground()
            }
        }
    }
    @Published private(set) var backgroundAppearanceRevision: UInt64 = 0
    private let hiddenWebViewDiscardManager = BrowserHiddenWebViewDiscardManager()

    @Published private(set) var webViewLifecycleState: BrowserWebViewLifecycleState = .newTab
    private(set) var webViewLastVisibleAt: Date?
    private(set) var webViewLastHiddenAt: Date?
    private(set) var webViewLastVisibilityChangeAt: Date?
    private(set) var webViewLastVisibilityChangeReason: String?
    var hasBackgroundPreloadHost: Bool {
        backgroundPreloadWindow != nil
    }
    private var shouldPreloadInitialNavigationInBackground: Bool
    private var backgroundPreloadWindow: NSWindow?
    private let visualAutomationCaptureGate = BrowserScreenshotCaptureGate()
    private var activeVisualAutomationCaptureCount: Int = 0
    private struct PendingInteractiveBrowserPrompt {
        let present: (NSWindow, @escaping () -> Void) -> Void
        let cancel: () -> Void
    }
    private var pendingInteractiveBrowserPrompts: [PendingInteractiveBrowserPrompt] = []
    private var isPresentingPendingInteractiveBrowserPrompt = false
    private var isWebViewVisibleInUI: Bool = false
    private var isClosingWebViewLifecycle: Bool = false

    /// True while a canvas pane hosts this browser's webview inline (in the
    /// pane's own hierarchy). Portal-side reconcilers must not rebind or
    /// re-sync the webview into the window portal while this is set.
    var canvasInlineHostingActive: Bool = false

    /// True when the browser is showing the internal empty new-tab page.
    var isShowingNewTabPage: Bool {
        !shouldRenderWebView && preferredURLStringForOmnibar() == nil
    }

    var isShowingBlankBrowserPage: Bool {
        Self.isBlankBrowserPage(
            liveURL: Self.restorableDisplayURL(
                liveURL: webView.url,
                currentURL: currentURL,
                activeErrorPageDisplayURL: navigationDelegate?.activeErrorPageDisplayURL
            ) ?? webView.url,
            currentURL: currentURL,
            pendingNavigationURL: BrowserRemoteProxyURLRewriter.displayURL(for: navigationDelegate?.lastAttemptedURL)
                ?? navigationDelegate?.lastAttemptedURL,
            isMainFrameProvisionalNavigationActive: isMainFrameProvisionalNavigationActive
        )
    }

    /// Published page title
    @Published private(set) var pageTitle: String = ""
    /// URL of the locally-rendered PDF for the current page, when the browser is
    /// displaying a PDF document (drives the PDF toolbar/print actions in
    /// BrowserPanel+PDFDocumentActions / BrowserPDFDocumentToolbarButtons).
    /// Restored during the main merge; the navigation-delegate PDF-detection that
    /// sets this is a deferred follow-up, so it stays nil (PDF actions hidden)
    /// until that wiring is ported. Consumers read it safely either way.
    @Published private(set) var renderedPDFDocumentURL: URL?

    /// Published favicon (PNG data). When present, the tab bar can render it instead of a SF symbol.
    @Published private(set) var faviconPNGData: Data?

    /// Published loading state
    @Published private(set) var isLoading: Bool = false

    /// Published download state for browser downloads (navigation + context menu).
    @Published private(set) var isDownloading: Bool = false

    /// Per-pane browser audio mute intent. BrowserPanel owns this so the state
    /// survives WKWebView replacement and can be applied to each new page.
    @Published private(set) var isMuted: Bool = false

    /// Published can go back state
    @Published private(set) var canGoBack: Bool = false

    /// Published can go forward state
    @Published private(set) var canGoForward: Bool = false

    var nativeCanGoBack: Bool = false
    var nativeCanGoForward: Bool = false

    /// The replayable back/forward session history this surface restores from a
    /// prior launch. The pure stack state machine and its reconciliation flows
    /// live in `CmuxBrowser.BrowserSessionHistoryCoordinator`; this surface owns
    /// the coordinator, feeds it live WebKit state through the
    /// `BrowserSessionHistoryHosting` seam, and performs the `WKWebView` calls its
    /// decisions return. The temporary-URL classification (diff viewer + remote
    /// loopback proxy alias) is inverted into the injected sanitizer seam.
    private let sessionHistoryCoordinator: BrowserSessionHistoryCoordinator

    private var usesRestoredSessionHistory: Bool {
        sessionHistoryCoordinator.usesRestoredSessionHistory
    }
    private var restoredHistoryCurrentURL: URL? {
        sessionHistoryCoordinator.restoredHistoryCurrentURL
    }
    private var restoredSessionHistoryHasState: Bool {
        sessionHistoryCoordinator.hasRestoredState
    }
    private var isMainFrameProvisionalNavigationActive: Bool = false

    /// Published estimated progress (0.0 - 1.0)
    @Published private(set) var estimatedProgress: Double = 0.0

    /// Increment to request a UI-only flash highlight (e.g. from a keyboard shortcut).
    @Published private(set) var focusFlashToken: Int = 0

    /// Browser focus mode gives the focused WKWebView first ownership of page/app shortcuts.
    @Published private(set) var isBrowserFocusModeActive: Bool = false

    /// A first plain Escape in browser focus mode is forwarded to the page and arms exit.
    @Published private(set) var isBrowserFocusModeExitArmed: Bool = false

    private static let browserFocusModeEscapeSequenceInterval: TimeInterval = 1.6
    private var browserFocusModeExitArmedAt: TimeInterval?
    private var lastBrowserFocusModePlainEscapeEventFingerprint: BrowserFocusModePlainEscapeEventFingerprint?

    /// Sticky omnibar-focus intent. This survives view mount timing races and is
    /// cleared only after BrowserPanelView acknowledges handling it.
    @Published private(set) var pendingAddressBarFocusRequestId: UUID?
    private(set) var pendingAddressBarFocusSelectionIntent: BrowserAddressBarFocusSelectionIntent = .preserveFieldEditorSelection

    /// Per-surface browser chrome visibility. Diff and artifact viewers can hide
    /// the omnibar without changing the global browser default.
    @Published private(set) var isOmnibarVisible: Bool

    /// Semantic in-panel focus target used by split switching and transient overlays.
    private(set) var preferredFocusIntent: BrowserPanelFocusIntent = .webView

    /// Incremented whenever async browser find focus ownership changes. Settable
    /// so the find-focus lease in `CmuxBrowser.BrowserFindCoordinator` can bump it
    /// through `BrowserFindHosting`; the find bar still observes the published value.
    @Published var searchFocusRequestGeneration: UInt64 = 0
    private var lastSearchNeedle = ""

    /// Find-in-page state. Non-nil when the find bar is visible.
    @Published var searchState: BrowserSearchState? = nil {
        didSet {
            if let searchState {
                clearBrowserFocusMode(reason: "searchStateCreated")
                preferredFocusIntent = .findField
#if DEBUG
                cmuxDebugLog("browser.find.state.created panel=\(id.uuidString.prefix(5))")
#endif
                searchNeedleCancellable = searchState.$needle
                    .removeDuplicates()
                    .map { needle -> AnyPublisher<String, Never> in
                        if needle.isEmpty || needle.count >= 3 {
                            return Just(needle).eraseToAnyPublisher()
                        }
                        return Just(needle)
                            .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
                            .eraseToAnyPublisher()
                    }
                    .switchToLatest()
                    .sink { [weak self] needle in
                        guard let self else { return }
#if DEBUG
                        cmuxDebugLog("browser.find.needle.updated panel=\(self.id.uuidString.prefix(5)) bytes=\(needle.lengthOfBytes(using: .utf8))")
#endif
                        self.findCoordinator.executeFindSearch(needle)
                    }
            } else if let oldValue {
                lastSearchNeedle = oldValue.needle
                searchNeedleCancellable = nil
                if preferredFocusIntent == .findField { preferredFocusIntent = .webView }
                findCoordinator.invalidateSearchFocusRequests(reason: "searchStateCleared")
#if DEBUG
                cmuxDebugLog("browser.find.state.cleared panel=\(id.uuidString.prefix(5))")
#endif
                findCoordinator.executeFindClear()
            }
        }
    }
    @Published private(set) var isElementFullscreenActive: Bool = false
    private var searchNeedleCancellable: AnyCancellable?

    /// Find-in-page orchestration (search/clear execution, match-count apply, the
    /// focus-request lease, and navigation replay) lives in
    /// `CmuxBrowser.BrowserFindCoordinator` over its `BrowserFindService`; this
    /// panel owns the live witnesses, the `@Published` `searchState`, the published
    /// focus generation, `preferredFocusIntent`, and the panel-id search-focus
    /// notification posts, exposed through `BrowserFindHosting`. The service
    /// evaluates find scripts against the panel's live `webView` through
    /// ``BrowserFindWebViewEvaluator``.
    private lazy var findCoordinator: BrowserFindCoordinator = {
        let coordinator = BrowserFindCoordinator(
            service: BrowserFindService(evaluator: BrowserFindWebViewEvaluator(panel: self))
        )
        coordinator.host = self
        return coordinator
    }()
    let portalAnchorView = BrowserPortalAnchorView(frame: .zero)
    private struct PortalHostLease {
        let hostId: ObjectIdentifier
        let paneId: UUID
        let inWindow: Bool
        let area: CGFloat
    }
    private struct PortalHostLock {
        let hostId: ObjectIdentifier
        let paneId: UUID
    }
    private enum DeveloperToolsPresentation {
        case unknown
        case attached
        case detached
    }
    private var activePortalHostLease: PortalHostLease?
    private var pendingDistinctPortalHostReplacementPaneId: UUID?
    private var lockedPortalHost: PortalHostLock?
    private var webViewCancellables = Set<AnyCancellable>()
    private var navigationDelegate: BrowserNavigationDelegate?
    private var uiDelegate: BrowserUIDelegate?
    private var downloadDelegate: BrowserDownloadDelegate?
    private let webAuthnCoordinator = BrowserWebAuthnCoordinator()
    private var webViewObservers: [NSKeyValueObservation] = []

    // Avoid flickering the loading indicator for very fast navigations.
    private let minLoadingIndicatorDuration: TimeInterval = 0.35
    private var loadingStartedAt: Date?
    private var loadingEndWorkItem: DispatchWorkItem?
    private var loadingGeneration: Int = 0

    /// Favicon-refresh state machine (generation/sequencing, SPA retry-once,
    /// skip-cached) lives in `CmuxBrowser.BrowserFaviconCoordinator`; this surface
    /// owns the live `WKWebView`, the remote-proxy session, and `@Published`
    /// `faviconPNGData` behind the `BrowserFaviconHosting` seam.
    private let faviconCoordinator: BrowserFaviconCoordinator
    private let zoomPolicy = BrowserZoomPolicy()
    /// Page-zoom affordance (in/out/reset/set + clamp-and-fire-on-change apply)
    /// lives in `CmuxBrowser.BrowserZoomCoordinator`; this panel owns the only
    /// live witness, `webView.pageZoom`, exposed through `BrowserZoomHosting`.
    private let zoomCoordinator = BrowserZoomCoordinator()

    /// Download-activity tally (count + `wasDownloading -> isDownloading` edge +
    /// which discard hook to fire) lives in
    /// `CmuxBrowser.BrowserDownloadActivityCoordinator`; this panel owns the only
    /// live witnesses, the published `isDownloading` flag and the discard
    /// scheduler, exposed through `BrowserDownloadActivityHosting`.
    private let downloadActivityCoordinator = BrowserDownloadActivityCoordinator()
    private let navigationIntentCoordinator: BrowserNavigationIntentCoordinator
    private var insecureHTTPAlertFactory: () -> NSAlert
    private var insecureHTTPAlertWindowProvider: () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }
    // Persist user intent across WebKit detach/reattach churn (split/layout updates).
    @Published private(set) var preferredDeveloperToolsVisible: Bool = false
    @Published var isReactGrabActive: Bool = false {
        didSet {
            guard oldValue != isReactGrabActive else { return }
            reevaluateHiddenWebViewDiscardScheduling(reason: "react_grab_changed")
        }
    }
    var reactGrabMessageHandler: ReactGrabMessageHandler?
    /// Whether the live page currently has any actively-playing `<video>` or
    /// `<audio>` element, in the main frame or any iframe, reported by the
    /// injected media-playback hook. Keeps an actively-playing pane alive in the
    /// background instead of being discarded after the hidden delay
    /// (https://github.com/manaflow-ai/cmux/issues/5409).
    private(set) var isPlayingMedia: Bool = false {
        didSet {
            guard oldValue != isPlayingMedia else { return }
            reevaluateHiddenWebViewDiscardScheduling(reason: "media_playback_changed")
        }
    }
    /// Live media activity. ``Workspace`` publishes it to tab/sidebar surfaces.
    /// (Restored to main's audio-aware shape during the merge; the Workspace-side
    /// fold that reads `onMediaActivityChanged` into `Workspace.browserMediaActivity`
    /// is a deferred follow-up.)
    private(set) var mediaActivity = BrowserMediaActivity()
    var isPlayingAudio: Bool { mediaActivity.isPlayingAudio }
    var isUsingMicrophone: Bool { mediaActivity.isUsingMicrophone }
    var isUsingCamera: Bool { mediaActivity.isUsingCamera }
    var onMediaActivityChanged: ((BrowserMediaActivity) -> Void)?
    /// Frame ids reporting playing media; keeps hidden panes alive while non-empty.
    private var playingMediaFrameIDs: Set<String> = []
    private var audibleMediaFrameIDs: Set<String> = []
    var mediaPlaybackMessageHandler: BrowserMediaPlaybackMessageHandler?

    private func setMediaActivity(
        isPlayingAudio: Bool? = nil,
        isUsingMicrophone: Bool? = nil,
        isUsingCamera: Bool? = nil,
        reason: String
    ) {
        var next = mediaActivity
        if let isPlayingAudio { next.isPlayingAudio = isPlayingAudio }
        if let isUsingMicrophone { next.isUsingMicrophone = isUsingMicrophone }
        if let isUsingCamera { next.isUsingCamera = isUsingCamera }
        guard next != mediaActivity else { return }
        mediaActivity = next
        onMediaActivityChanged?(next)
        reevaluateHiddenWebViewDiscardScheduling(reason: reason)
    }

    /// Folds a per-frame playback report into retention and audio-glyph state.
    func applyMediaPlaybackReport(frameID: String, isPlaying: Bool, isAudible: Bool) {
        if isPlaying { playingMediaFrameIDs.insert(frameID) } else { playingMediaFrameIDs.remove(frameID) }
        if isPlaying && isAudible { audibleMediaFrameIDs.insert(frameID) } else { audibleMediaFrameIDs.remove(frameID) }
        isPlayingMedia = !playingMediaFrameIDs.isEmpty
        refreshAudioMediaActivity(reason: "media_audibility_changed")
    }

    /// Clears tracked frames after a webview bind or main-frame navigation.
    func resetMediaPlaybackTracking() {
        (playingMediaFrameIDs, audibleMediaFrameIDs) = ([], [])
        isPlayingMedia = false
        refreshAudioMediaActivity(reason: "media_playback_reset")
    }

    private func refreshAudioMediaActivity(reason: String) { setMediaActivity(isPlayingAudio: !audibleMediaFrameIDs.isEmpty && !isMuted, reason: reason) }
    var pendingReactGrabReturnTargetPanelId: UUID?
    var pendingReactGrabRoundTripToken: String?
    let reactGrabBridgeSessionUpdaterName = "__cmuxReactGrabBridgeSync_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    private var preferredDeveloperToolsPresentation: DeveloperToolsPresentation = .unknown
    private var forceDeveloperToolsRefreshOnNextAttach: Bool = false
    private var developerToolsRestoreRetryWorkItem: DispatchWorkItem?
    private var developerToolsRestoreRetryAttempt: Int = 0
    private let developerToolsRestoreRetryDelay: TimeInterval = 0.05
    private let developerToolsRestoreRetryMaxAttempts: Int = 40
    private var remoteProxyEndpoint: BrowserProxyEndpoint?
    @Published private(set) var remoteWorkspaceStatus: BrowserRemoteWorkspaceStatus?
    private(set) var usesRemoteWorkspaceProxy: Bool
    private let bypassesRemoteWorkspaceProxy: Bool
    /// Marks this surface as transparent internal cmux UI (e.g. the diff viewer
    /// or other custom UI) rather than a normal web page. When set, the webview
    /// is made fully clear over a transparent Ghostty theme so the page's own
    /// CSS owns the background. See `applyWebViewBackground(color:)`.
    private let usesTransparentBackground: Bool
    private let developerToolsDetachedOpenGracePeriod: TimeInterval = 0.35
    private var developerToolsDetachedOpenGraceDeadline: Date?
    private var developerToolsTransitionTargetVisible: Bool?
    private var pendingDeveloperToolsTransitionTargetVisible: Bool?
    private var developerToolsTransitionSettleWorkItem: DispatchWorkItem?
    private var developerToolsVisibilityLossCheckWorkItem: DispatchWorkItem?
    private let developerToolsTransitionSettleDelay: TimeInterval = 0.15
    private let developerToolsAttachedManualCloseDetectionDelay: TimeInterval = 0.35
    private let developerToolsDetachedWindowCloseResolutionMaxDuration: TimeInterval = 2.0
    private var developerToolsLastAttachedHostAt: Date?
    private var developerToolsLastKnownVisibleAt: Date?
    private var detachedDeveloperToolsWindowCloseObserver: NSObjectProtocol?
    // One-shot DispatchSourceTimer bridges WebKit's synchronous window-close
    // callback to a bounded redock deadline.
    private var detachedDeveloperToolsWindowCloseResolutionTimer: DispatchSourceTimer?
    private var detachedDeveloperToolsWindowCloseResolutionGeneration: UInt64 = 0
    private var preferredAttachedDeveloperToolsWidth: CGFloat?
    private var preferredAttachedDeveloperToolsWidthFraction: CGFloat?
    private var browserThemeMode: BrowserThemeMode

    var displayTitle: String {
        if !pageTitle.isEmpty {
            return pageTitle
        }
        if let url = currentURL {
            return url.host ?? url.absoluteString
        }
        return String(localized: "browser.newTab", defaultValue: "New tab")
    }

    var profileDisplayName: String {
        BrowserProfileStore.shared.displayName(for: profileID)
    }

    var usesBuiltInDefaultProfile: Bool {
        profileID == BrowserProfileStore.shared.builtInDefaultProfileID
    }

    var currentBrowserThemeMode: BrowserThemeMode {
        browserThemeMode
    }

    @discardableResult
    private func applyMuteState(_ muted: Bool? = nil, to webView: WKWebView, reason: String) -> Bool {
        let targetMuted = muted ?? isMuted
        let applied = webView.cmuxSetPageAudioMuted(targetMuted)
#if DEBUG
        if !applied {
            cmuxDebugLog(
                "browser.audioMute.applyUnavailable panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) muted=\(targetMuted ? 1 : 0)"
            )
        }
#endif
        return applied
    }

    func noteWebViewVisibility(
        _ visible: Bool,
        reason: String,
        now: Date = Date(),
        recordIfUnchanged: Bool = false
    ) {
        let changed = isWebViewVisibleInUI != visible
        let isFirstVisibilityRecord = webViewLastVisibilityChangeReason == nil
        let shouldRecordVisibleHeartbeat = visible && recordIfUnchanged
        guard changed || shouldRecordVisibleHeartbeat || isFirstVisibilityRecord else {
            refreshWebViewLifecycleState()
            return
        }

        if changed || isFirstVisibilityRecord {
            isWebViewVisibleInUI = visible
            if visible {
                webViewLastVisibleAt = now
            } else {
                webViewLastHiddenAt = now
            }
            webViewLastVisibilityChangeAt = now
            webViewLastVisibilityChangeReason = reason
        } else if shouldRecordVisibleHeartbeat {
            webViewLastVisibleAt = now
        }
        refreshWebViewLifecycleState()

        if visible {
            cancelHiddenWebViewDiscard()
            restoreDiscardedWebViewIfNeeded(reason: "visible.\(reason)")
            drainPendingInteractiveBrowserPromptsIfPossible(reason: "visible.\(reason)")
        } else if changed || isFirstVisibilityRecord || !hiddenWebViewDiscardManager.hasScheduledDiscard {
            scheduleHiddenWebViewDiscardIfNeeded(reason: reason)
        }
    }

    func webViewLifecycleTopPayload(now: Date = Date()) -> [String: Any] {
        let discardBlockers = hiddenWebViewDiscardBlockers()
        return [
            "state": webViewLifecycleState.rawValue,
            "visible_in_ui": isWebViewVisibleInUI,
            "should_render": shouldRenderWebView,
            "discard_eligible": discardBlockers.isEmpty,
            "discard_blockers": discardBlockers,
            "discarded_at": Self.webViewLifecycleTimestamp(hiddenWebViewDiscardManager.discardedAt),
            "last_discard_reason": hiddenWebViewDiscardManager.lastDiscardReason.map { $0 as Any } ?? NSNull(),
            "last_restore_reason": hiddenWebViewDiscardManager.lastRestoreReason.map { $0 as Any } ?? NSNull(),
            "last_visible_at": Self.webViewLifecycleTimestamp(webViewLastVisibleAt),
            "last_hidden_at": Self.webViewLifecycleTimestamp(webViewLastHiddenAt),
            "last_visibility_change_at": Self.webViewLifecycleTimestamp(webViewLastVisibilityChangeAt),
            "last_visibility_change_reason": webViewLastVisibilityChangeReason.map { $0 as Any } ?? NSNull(),
            "hidden_duration_ms": Self.webViewHiddenDurationMilliseconds(
                hiddenAt: webViewLastHiddenAt,
                visible: isWebViewVisibleInUI,
                now: now
            )
        ]
    }

    private func refreshWebViewLifecycleState() {
        let nextState: BrowserWebViewLifecycleState
        if isClosingWebViewLifecycle {
            nextState = .closing
        } else if hiddenWebViewDiscardManager.isDiscardedForMemory {
            nextState = .discarded
        } else if !shouldRenderWebView {
            nextState = preferredURLStringForOmnibar() == nil ? .newTab : .deferredURL
        } else if isWebViewVisibleInUI {
            nextState = .liveVisible
        } else {
            nextState = .liveHidden
        }
        guard webViewLifecycleState != nextState else { return }
        webViewLifecycleState = nextState
    }

    private static let webViewLifecycleTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func webViewLifecycleTimestamp(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return webViewLifecycleTimestampFormatter.string(from: date)
    }

    private static func webViewHiddenDurationMilliseconds(
        hiddenAt: Date?,
        visible: Bool,
        now: Date
    ) -> Any {
        guard !visible, let hiddenAt else { return NSNull() }
        return max(0, Int((now.timeIntervalSince(hiddenAt) * 1000.0).rounded()))
    }

    private func resetWebViewLifecycleMetadata(resetVisibility: Bool = true) {
        cancelHiddenWebViewDiscard()
        webViewLifecycleState = .newTab
        if resetVisibility {
            webViewLastVisibleAt = nil
            webViewLastHiddenAt = nil
            webViewLastVisibilityChangeAt = nil
            webViewLastVisibilityChangeReason = nil
            isWebViewVisibleInUI = false
        }
        hiddenWebViewDiscardManager.resetMetadata()
        isClosingWebViewLifecycle = false
    }

    private func hiddenWebViewDiscardBlockers() -> [String] {
        hiddenWebViewDiscardManager.blockers(for: hiddenWebViewDiscardSnapshot)
    }

    func scheduleHiddenWebViewDiscardIfNeeded(reason: String) {
        hiddenWebViewDiscardManager.scheduleIfNeeded(reason: reason)
    }

    /// Immediately discards this panel's hidden WebView when safe, in response to
    /// system memory pressure. Returns `true` when a discard happened.
    @discardableResult
    func discardHiddenWebViewForSystemMemoryPressure(now: Date = Date()) -> Bool {
        hiddenWebViewDiscardManager.requestImmediateDiscardIfSafe(reason: "system_memory_pressure", now: now)
    }

    private func cancelHiddenWebViewDiscard() {
        hiddenWebViewDiscardManager.cancel()
    }

    func reevaluateHiddenWebViewDiscardScheduling(reason: String) {
        if isWebViewVisibleInUI {
            cancelHiddenWebViewDiscard()
        } else {
            scheduleHiddenWebViewDiscardIfNeeded(reason: reason)
        }
    }

    private func installHiddenWebViewDiscardPolicyObserver() {
        hiddenWebViewDiscardManager.installPolicyObserver()
        hiddenWebViewDiscardManager.installSystemSleepObservers()
    }

    @discardableResult
    func discardHiddenWebViewForMemory(reason: String, now: Date = Date()) -> Bool {
        let blockers = hiddenWebViewDiscardBlockers()
        guard blockers.isEmpty else { return false }

        cancelHiddenWebViewDiscard()

        let oldWebView = webView
        let restoreURL = Self.restorableDisplayURL(
            liveURL: oldWebView.url,
            currentURL: currentURL,
            activeErrorPageDisplayURL: navigationDelegate?.activeErrorPageDisplayURL
        )
        let history = sessionNavigationHistorySnapshot()
        let historyCurrentURL = preferredURLStringForOmnibar() ?? restoreURL?.absoluteString
        let desiredZoom = zoomPolicy.clamp(oldWebView.pageZoom)

        clearBrowserFocusMode(reason: "webViewDiscard")
        invalidateSearchFocusRequests(reason: "webViewDiscard")
        searchState = nil
        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil
        faviconCoordinator.cancelInFlightRefreshInvalidatingGeneration()
        loadingGeneration &+= 1
        cancelPendingInteractiveBrowserPrompts(reason: "discardHiddenWebView")

        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        closeBackgroundPreloadHost(reason: "discardHiddenWebView")
        BrowserWindowPortalRegistry.detach(webView: oldWebView)
        webAuthnCoordinator.uninstall(from: oldWebView)
        oldWebView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
        oldWebView.navigationDelegate = nil
        oldWebView.uiDelegate = nil
        if let oldCmuxWebView = oldWebView as? CmuxWebView {
            oldCmuxWebView.onContextMenuDownloadStateChanged = nil
        }

        let replacement = Self.makeWebView(
            profileID: profileID,
            websiteDataStore: websiteDataStore
        )
        replacement.pageZoom = desiredZoom
        webViewInstanceID = UUID()
        webView = replacement
        hiddenWebViewDiscardManager.markDiscarded(reason: reason, now: now)
        currentURL = restoreURL
        shouldRenderWebView = false
        nativeCanGoBack = false
        nativeCanGoForward = false
        isLoading = false
        estimatedProgress = 0
        activePortalHostLease = nil
        pendingDistinctPortalHostReplacementPaneId = nil
        lockedPortalHost = nil

        bindWebView(replacement)
        applyProxyConfigurationIfAvailable()
        applyBrowserThemeModeIfNeeded()
        restoreSessionNavigationHistory(
            backHistoryURLStrings: history.backHistoryURLStrings,
            forwardHistoryURLStrings: history.forwardHistoryURLStrings,
            currentURLString: historyCurrentURL
        )
        refreshNavigationAvailability()
        refreshWebViewLifecycleState()
        return true
    }

    @discardableResult
    func restoreDiscardedWebViewIfNeeded(
        reason: String,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) -> Bool {
        return hiddenWebViewDiscardManager.restoreIfNeeded(reason: reason) {
            shouldRenderWebView = true
            guard let restoreURL = restoredHistoryCurrentURL ?? currentURL else {
                refreshNavigationAvailability()
                return
            }
            navigateWithoutInsecureHTTPPrompt(
                to: restoreURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true,
                cachePolicy: cachePolicy
            )
        }
    }

    private func clearWebViewDiscardState(reason: String) {
        guard hiddenWebViewDiscardManager.clearDiscardState(reason: reason) else { return }
        refreshWebViewLifecycleState()
    }

    @discardableResult
    private func reactivateDiscardedWebViewWithoutNavigation(reason: String) -> Bool {
        return hiddenWebViewDiscardManager.reactivateWithoutNavigation(reason: reason) {
            shouldRenderWebView = true
        }
    }

    /// Popups inherit this panel's exact WebKit storage context.
    var popupBrowserContext: BrowserPopupBrowserContext {
        BrowserPopupBrowserContext(
            websiteDataStore: websiteDataStore
        )
    }

    private static let portalHostAreaThreshold: CGFloat = 4
    private static let portalHostReplacementAreaGainRatio: CGFloat = 1.2

    private static func portalHostArea(for bounds: CGRect) -> CGFloat {
        max(0, bounds.width) * max(0, bounds.height)
    }

    private static func portalHostIsUsable(_ lease: PortalHostLease) -> Bool {
        lease.inWindow && lease.area > portalHostAreaThreshold
    }

    func preparePortalHostReplacementForNextDistinctClaim(
        inPane paneId: PaneID,
        reason: String
    ) {
        pendingDistinctPortalHostReplacementPaneId = paneId.id
        if lockedPortalHost?.paneId == paneId.id {
            lockedPortalHost = nil
        }
#if DEBUG
        cmuxDebugLog(
            "browser.portal.host.rearm panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) pane=\(paneId.id.uuidString.prefix(5))"
        )
#endif
    }

    func claimPortalHost(
        hostId: ObjectIdentifier,
        paneId: PaneID,
        inWindow: Bool,
        bounds: CGRect,
        reason: String
    ) -> Bool {
        if shouldUseLocalInlineDeveloperToolsHosting() {
            activePortalHostLease = nil
            lockedPortalHost = nil
#if DEBUG
            cmuxDebugLog(
                "browser.portal.host.skip panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason).localInlineDevTools host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            return false
        }

        let next = PortalHostLease(
            hostId: hostId,
            paneId: paneId.id,
            inWindow: inWindow,
            area: Self.portalHostArea(for: bounds)
        )

        if let current = activePortalHostLease {
            if let lock = lockedPortalHost,
               (lock.hostId != current.hostId || lock.paneId != current.paneId) {
                lockedPortalHost = nil
            }

            if current.hostId == hostId {
                activePortalHostLease = next
                return true
            }

            let currentUsable = Self.portalHostIsUsable(current)
            let nextUsable = Self.portalHostIsUsable(next)
            let isSamePaneReplacement = current.paneId == paneId.id
            let shouldForceDistinctReplacement =
                isSamePaneReplacement &&
                pendingDistinctPortalHostReplacementPaneId == paneId.id &&
                inWindow
            if shouldForceDistinctReplacement {
#if DEBUG
                cmuxDebugLog(
                    "browser.portal.host.claim panel=\(id.uuidString.prefix(5)) " +
                    "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                    "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                    "replacingHost=\(current.hostId) replacingPane=\(current.paneId.uuidString.prefix(5)) " +
                    "replacingInWin=\(current.inWindow ? 1 : 0) replacingArea=\(String(format: "%.1f", current.area)) " +
                    "forced=1"
                )
#endif
                activePortalHostLease = next
                pendingDistinctPortalHostReplacementPaneId = nil
                lockedPortalHost = PortalHostLock(hostId: hostId, paneId: paneId.id)
                return true
            }

            let lockBlocksSamePaneReplacement =
                isSamePaneReplacement &&
                currentUsable &&
                lockedPortalHost?.hostId == current.hostId &&
                lockedPortalHost?.paneId == current.paneId
            let shouldReplace =
                current.paneId != paneId.id ||
                !currentUsable ||
                (
                    !lockBlocksSamePaneReplacement &&
                    nextUsable &&
                    next.area > (current.area * Self.portalHostReplacementAreaGainRatio)
                )

            if shouldReplace {
                if lockedPortalHost?.hostId == current.hostId &&
                    lockedPortalHost?.paneId == current.paneId {
                    lockedPortalHost = nil
                }
#if DEBUG
                cmuxDebugLog(
                    "browser.portal.host.claim panel=\(id.uuidString.prefix(5)) " +
                    "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                    "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                    "replacingHost=\(current.hostId) replacingPane=\(current.paneId.uuidString.prefix(5)) " +
                    "replacingInWin=\(current.inWindow ? 1 : 0) replacingArea=\(String(format: "%.1f", current.area))"
                )
#endif
                activePortalHostLease = next
                return true
            }

#if DEBUG
            cmuxDebugLog(
                "browser.portal.host.skip panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                "ownerHost=\(current.hostId) ownerPane=\(current.paneId.uuidString.prefix(5)) " +
                "ownerInWin=\(current.inWindow ? 1 : 0) ownerArea=\(String(format: "%.1f", current.area)) " +
                "locked=\(lockBlocksSamePaneReplacement ? 1 : 0)"
            )
#endif
            return false
        }

        activePortalHostLease = next
#if DEBUG
        cmuxDebugLog(
            "browser.portal.host.claim panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
            "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
            "replacingHost=nil"
        )
#endif
        return true
    }

    @discardableResult
    func releasePortalHostIfOwned(hostId: ObjectIdentifier, reason: String) -> Bool {
        guard let current = activePortalHostLease, current.hostId == hostId else { return false }
        activePortalHostLease = nil
        if lockedPortalHost?.hostId == hostId {
            lockedPortalHost = nil
        }
#if DEBUG
        cmuxDebugLog(
            "browser.portal.host.release panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(current.paneId.uuidString.prefix(5)) " +
            "inWin=\(current.inWindow ? 1 : 0) area=\(String(format: "%.1f", current.area))"
        )
#endif
        return true
    }

    var displayIcon: String? {
        "globe"
    }

    var isDirty: Bool {
        false
    }

    // Internal so BrowserPrewarmedWebViewPool builds prewarm webviews with
    // identical configuration, making adoption a drop-in swap.
    static func makeWebView(
        profileID: UUID,
        websiteDataStore: WKWebsiteDataStore? = nil
    ) -> CmuxWebView {
        let config = WKWebViewConfiguration()
        configureWebViewConfiguration(
            config,
            websiteDataStore: websiteDataStore ?? BrowserProfileStore.shared.websiteDataStore(for: profileID)
        )

        let webView = CmuxWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        // Match only the unpainted/loading background so newly-created browsers don't flash
        // white before content loads. Do not force page appearance or inject color-scheme CSS;
        // websites must keep control of their own theme.
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
        // Always present as Safari.
        webView.customUserAgent = String.safariDesktopUserAgent
        return webView
    }

    static func configureWebViewConfiguration(
        _ configuration: WKWebViewConfiguration,
        websiteDataStore: WKWebsiteDataStore
    ) {
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Ensure browser cookies/storage persist across navigations and launches.
        // This reduces repeated consent/bot-challenge flows on sites like Google.
        configuration.websiteDataStore = websiteDataStore
        if configuration.urlSchemeHandler(forURLScheme: CmuxDiffViewerURLSchemeHandler.scheme) == nil {
            configuration.setURLSchemeHandler(
                CmuxDiffViewerURLSchemeHandler.shared,
                forURLScheme: CmuxDiffViewerURLSchemeHandler.scheme
            )
        }
        // Review-comment persistence + TextBox attach for diff viewer pages.
        // The handler itself rejects every frame that is not a registered diff
        // viewer session, so installing it on all browser webviews is safe.
        DiffCommentsBridge.installIfNeeded(on: configuration.userContentController)

        // Enable developer extras (DevTools)
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.preferences.isElementFullscreenEnabled = true

        // Enable JavaScript
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserFileSystemAccessBridgeScript().source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        // Keep browser console/error/dialog telemetry active from document start on every navigation.
        // Main frame only — injecting into cross-origin iframes causes CAPTCHA providers
        // (reCAPTCHA, hCaptcha, Cloudflare Turnstile) to detect the overridden console.*
        // methods and __cmux* globals as environment tampering, failing the challenge.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.telemetryHookBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: RemoteLoopbackRuntimeBridge.runtimeBridgeScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserWebAuthnBridgeContract.standard.scriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
        )
        // Track the last editable focused element continuously so omnibar exit can
        // restore page input focus even if capture runs after first-responder handoff.
        // Main frame only — same CAPTCHA interference concern as telemetry hooks.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserOmnibarPageFocusRepository.trackingBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        // Keep a native cache of whether the focused page element can currently accept
        // plain-text paste so Cmd+Shift+V is only consumed when the browser can use it.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserPasteAsPlainTextFocusContract().focusTrackingBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        // Report <video>/<audio> playback so a hidden pane with actively-playing
        // media is exempted from memory discard
        // (https://github.com/manaflow-ai/cmux/issues/5409). Injected into every
        // frame so embedded players in cross-origin iframes keep the pane alive
        // too. Runs in an isolated content world (shared DOM, separate JS scope)
        // so the handler is hidden from page JavaScript that could otherwise post
        // a fake playing report; this also keeps it clear of CAPTCHA fingerprint
        // checks in those iframes.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.mediaPlaybackTrackingBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: Self.mediaPlaybackContentWorld
            )
        )
    }

    private func bindWebView(_ webView: CmuxWebView) {
        DiffCommentsBridge.associate(panelId: id, workspaceId: workspaceId, with: webView)
        webView.onMouseBackButton = { [weak self] in
            self?.goBack()
        }
        webView.onMouseForwardButton = { [weak self] in
            self?.goForward()
        }
        webView.onContextMenuDownloadStateChanged = { [weak self] downloading in
            if downloading {
                self?.beginDownloadActivity()
            } else {
                self?.endDownloadActivity()
            }
        }
        webView.onSessionDownloadEvent = { [weak self] event in
            guard let self else { return }
            self.postBrowserDownloadEvent(event)
        }
        webView.onContextMenuOpenLinkInNewTab = { [weak self] url in
            self?.openLinkInNewTab(url: url)
        }
        configureMoveTabToNewWorkspaceContextMenu(for: webView); configureNavigationDelegateCallbacks()
        webView.cmuxDownloadDelegate = downloadDelegate
        webView.navigationDelegate = navigationDelegate
        webView.uiDelegate = uiDelegate
        setupObservers(for: webView)
        setupReactGrabMessageHandler(for: webView)
        setupMediaPlaybackMessageHandler(for: webView)
        webAuthnCoordinator.install(on: webView)
        applyMuteState(to: webView, reason: "bindWebView")
    }

    private func configureNavigationDelegateCallbacks() {
        guard let navigationDelegate else { return }
        let boundWebViewInstanceID = webViewInstanceID
        let boundHistoryStore = historyStore

        navigationDelegate.didStartProvisionalNavigation = { [weak self] webView in
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(webView, instanceID: boundWebViewInstanceID) else { return }
                self.isMainFrameProvisionalNavigationActive = true
                self.refreshBackgroundAppearance()
                self.applyMuteState(to: webView, reason: "navigationStart")
            }
        }
        navigationDelegate.didCommit = { [weak self] webView in
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(webView, instanceID: boundWebViewInstanceID) else { return }
                self.isMainFrameProvisionalNavigationActive = false
                // Reset playback tracking only once the new top-level document has
                // actually replaced the old one. Resetting earlier (on provisional
                // start) would drop a still-playing page's frames if the
                // navigation then fails or is canceled, letting a playing pane be
                // discarded. didCommit does not fire for same-document (pushState)
                // navigations, so a persisting SPA video keeps its frame id.
                self.resetMediaPlaybackTracking()
                self.publishCommittedURL(from: webView)
                self.applyMuteState(to: webView, reason: "navigationCommit")
            }
        }
        navigationDelegate.didFinish = { [weak self] webView in
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(webView, instanceID: boundWebViewInstanceID) else { return }
                self.isMainFrameProvisionalNavigationActive = false
                self.publishCommittedURL(from: webView)
                self.applyMuteState(to: webView, reason: "navigationFinish")
                if self.navigationDelegate?.activeErrorPageDisplayURL == nil {
                    self.realignRestoredSessionHistoryToLiveCurrentIfPossible()
                    boundHistoryStore.recordVisit(url: webView.url, title: webView.title)
                    self.faviconCoordinator.refreshFavicon()
                }
                // Keep find-in-page open through load completion and refresh matches for the new DOM.
                self.restoreFindStateAfterNavigation(replaySearch: true)
            }
        }
        navigationDelegate.didFailNavigation = { [weak self] failedWebView, failedURL in
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(failedWebView, instanceID: boundWebViewInstanceID) else { return }
                self.isMainFrameProvisionalNavigationActive = false
                if let url = URL(string: failedURL) {
                    self.currentURL = BrowserRemoteProxyURLRewriter.displayURL(for: url) ?? url
                }
                // Clear stale title/favicon from the previous page so the tab
                // shows the failed URL instead of the old page's branding.
                self.pageTitle = failedURL.isEmpty ? "" : failedURL
                self.faviconPNGData = nil
                self.faviconCoordinator.clearLastFaviconURLString()
                self.applyMuteState(to: failedWebView, reason: "navigationFail")
                // Keep find-in-page open and clear stale counters on failed loads.
                self.restoreFindStateAfterNavigation(replaySearch: false)
            }
        }
        navigationDelegate.didCancelProvisionalNavigation = { [weak self] webView in
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(webView, instanceID: boundWebViewInstanceID) else { return }
                self.isMainFrameProvisionalNavigationActive = false
                self.navigationDelegate?.lastAttemptedURL = nil
                self.refreshBackgroundAppearance()
            }
        }
    }

    private func publishCommittedURL(from webView: WKWebView) {
        if let displayURL = Self.restorableDisplayURL(
            liveURL: webView.url,
            currentURL: currentURL,
            activeErrorPageDisplayURL: navigationDelegate?.activeErrorPageDisplayURL
        ) {
            currentURL = displayURL
        } else {
            currentURL = BrowserRemoteProxyURLRewriter.displayURL(for: webView.url)
        }
        navigationDelegate?.clearAttemptedRequest()
        refreshBackgroundAppearance()
        GlobalSearchCoordinator.shared.captureBrowserPanel(self)
    }

    private func isCurrentWebView(_ candidate: WKWebView, instanceID: UUID? = nil) -> Bool {
        guard candidate === webView else { return false }
        guard let instanceID else { return true }
        return instanceID == webViewInstanceID
    }

    /// Tracks whether the process-once browser defaults bootstrap has run.
    private static var hasBootstrappedBrowserDefaults = false

    /// Registers browser fallback defaults and normalizes any legacy/out-of-range
    /// stored settings to their canonical form, exactly once per process.
    ///
    /// This is app-once work, not per-view work. Keeping it out of
    /// `BrowserPanelView.onAppear` is what fixes the issue #5303 render loop:
    /// `.onAppear` can re-fire on every CoreAnimation commit for a portal-hosted
    /// pane, and a view-scoped `@State` guard resets whenever the view changes
    /// identity (a remount re-runs it). A process-scoped guard runs the work once
    /// regardless of how many panels or view instances come and go.
    ///
    /// Always targets `UserDefaults.standard`: the guard is process-wide, so an
    /// injectable suite here would silently no-op for every caller after the first.
    /// Tests exercise ``normalizeBrowserDefaults(defaults:)`` directly with a
    /// scratch suite instead.
    static func bootstrapBrowserDefaultsIfNeeded() {
        guard !hasBootstrappedBrowserDefaults else { return }
        hasBootstrappedBrowserDefaults = true
        normalizeBrowserDefaults(defaults: .standard)
    }

    /// Registers fallback defaults and writes back canonical values for any stored
    /// browser setting whose raw value is legacy or out of range.
    ///
    /// Pure with respect to the injected `defaults`, so it is unit-testable against
    /// a scratch `UserDefaults(suiteName:)` without touching `UserDefaults.standard`.
    static func normalizeBrowserDefaults(defaults: UserDefaults) {
        defaults.register(defaults: [
            BrowserSearchSettingsStore.searchEngineKey: BrowserSearchSettingsStore.defaultSearchEngine.rawValue,
            BrowserSearchSettingsStore.customSearchEngineNameKey: BrowserSearchSettingsStore.defaultCustomSearchEngineName,
            BrowserSearchSettingsStore.customSearchEngineURLTemplateKey: BrowserSearchSettingsStore.defaultCustomSearchEngineURLTemplate,
            BrowserSearchSettingsStore.searchSuggestionsEnabledKey: BrowserSearchSettingsStore.defaultSearchSuggestionsEnabled,
            BrowserToolbarAccessorySpacingStore.key: BrowserToolbarAccessorySpacingStore.defaultSpacing,
            BrowserProfilePopoverPaddingStore.horizontalPaddingKey: BrowserProfilePopoverPaddingStore.defaultHorizontalPadding,
            BrowserProfilePopoverPaddingStore.verticalPaddingKey: BrowserProfilePopoverPaddingStore.defaultVerticalPadding,
            BrowserThemeSettings.modeKey: BrowserThemeSettings.defaultMode.rawValue,
        ])

        let resolvedThemeMode = BrowserThemeSettings.mode(defaults: defaults)
        let currentThemeRaw = defaults.string(forKey: BrowserThemeSettings.modeKey)
            ?? BrowserThemeSettings.defaultMode.rawValue
        if currentThemeRaw != resolvedThemeMode.rawValue {
            defaults.set(resolvedThemeMode.rawValue, forKey: BrowserThemeSettings.modeKey)
        }

        let resolvedHintVariant = BrowserImportHintSettings(defaults: defaults).variant()
        let currentHintRaw = defaults.string(forKey: BrowserImportHintSettings.variantKey)
            ?? BrowserImportHintSettings.defaultVariant.rawValue
        if currentHintRaw != resolvedHintVariant.rawValue {
            defaults.set(resolvedHintVariant.rawValue, forKey: BrowserImportHintSettings.variantKey)
        }

        let resolvedToolbarSpacing = BrowserToolbarAccessorySpacingStore(defaults: defaults).current()
        let currentToolbarSpacing = (defaults.object(forKey: BrowserToolbarAccessorySpacingStore.key) as? Int)
            ?? BrowserToolbarAccessorySpacingStore.defaultSpacing
        if currentToolbarSpacing != resolvedToolbarSpacing {
            defaults.set(resolvedToolbarSpacing, forKey: BrowserToolbarAccessorySpacingStore.key)
        }

        let popoverPaddingStore = BrowserProfilePopoverPaddingStore(defaults: defaults)
        let resolvedHorizontalPadding = popoverPaddingStore.currentHorizontalPadding()
        let currentHorizontalPadding = (defaults.object(forKey: BrowserProfilePopoverPaddingStore.horizontalPaddingKey) as? NSNumber)?.doubleValue
            ?? BrowserProfilePopoverPaddingStore.defaultHorizontalPadding
        if currentHorizontalPadding != resolvedHorizontalPadding {
            defaults.set(resolvedHorizontalPadding, forKey: BrowserProfilePopoverPaddingStore.horizontalPaddingKey)
        }

        let resolvedVerticalPadding = popoverPaddingStore.currentVerticalPadding()
        let currentVerticalPadding = (defaults.object(forKey: BrowserProfilePopoverPaddingStore.verticalPaddingKey) as? NSNumber)?.doubleValue
            ?? BrowserProfilePopoverPaddingStore.defaultVerticalPadding
        if currentVerticalPadding != resolvedVerticalPadding {
            defaults.set(resolvedVerticalPadding, forKey: BrowserProfilePopoverPaddingStore.verticalPaddingKey)
        }
    }

    init(
        workspaceId: UUID,
        profileID: UUID? = nil,
        initialURL: URL? = nil,
        initialRequest: URLRequest? = nil,
        renderInitialNavigation: Bool = true,
        preloadInitialNavigationInBackground: Bool = false,
        bypassInsecureHTTPHostOnce: String? = nil,
        omnibarVisible: Bool = true,
        transparentBackground: Bool = false,
        proxyEndpoint: BrowserProxyEndpoint? = nil,
        bypassRemoteProxy: Bool = false,
        isRemoteWorkspace: Bool = false,
        remoteWebsiteDataStoreIdentifier: UUID? = nil
    ) {
        // Register fallback defaults and normalize legacy/out-of-range settings once
        // per process, before any setting is read below or by the SwiftUI view.
        Self.bootstrapBrowserDefaultsIfNeeded()
        self.id = UUID()
        self.faviconCoordinator = BrowserFaviconCoordinator(panelID: self.id)
        self.workspaceId = workspaceId
        let resolvedProfileID = Self.resolvedProfileID(requested: profileID)
        self.profileID = resolvedProfileID
        self.historyStore = BrowserProfileStore.shared.historyStore(for: resolvedProfileID)
        self.navigationIntentCoordinator = BrowserNavigationIntentCoordinator(
            initialBypassHostOnce: BrowserInsecureHTTPSettings.normalizeHost(bypassInsecureHTTPHostOnce ?? "")
        )
        self.sessionHistoryCoordinator = BrowserSessionHistoryCoordinator(
            sanitizer: SessionHistoryURLSanitizer { $0?.isTemporaryBrowserHistory ?? false }
        )
        self.bypassesRemoteWorkspaceProxy = bypassRemoteProxy
        self.remoteProxyEndpoint = bypassRemoteProxy ? nil : proxyEndpoint
        self.usesRemoteWorkspaceProxy = isRemoteWorkspace && !bypassRemoteProxy
        self.browserThemeMode = BrowserThemeSettings.mode()
        self.shouldPreloadInitialNavigationInBackground = preloadInitialNavigationInBackground
        self.isOmnibarVisible = omnibarVisible
        self.usesTransparentBackground = transparentBackground
        let websiteDataStore = isRemoteWorkspace
            ? WKWebsiteDataStore(forIdentifier: remoteWebsiteDataStoreIdentifier ?? workspaceId)
            : BrowserProfileStore.shared.websiteDataStore(for: resolvedProfileID)
        self.websiteDataStore = websiteDataStore
        let webView: CmuxWebView
        var adoptedPrewarmedWebView = false
        if let prewarmed = Self.claimedPrewarmedWebView(
            isRemoteWorkspace: isRemoteWorkspace,
            initialRequest: initialRequest,
            renderInitialNavigation: renderInitialNavigation,
            initialURL: initialURL,
            profileID: resolvedProfileID,
            websiteDataStore: websiteDataStore
        ) {
            webView = prewarmed
            adoptedPrewarmedWebView = true
        } else {
            webView = Self.makeWebView(
                profileID: resolvedProfileID,
                websiteDataStore: websiteDataStore
            )
        }
        self.webView = webView
        self.insecureHTTPAlertFactory = { NSAlert() }
        hiddenWebViewDiscardManager.delegate = self
        applyProxyConfigurationIfAvailable()
        BrowserProfileStore.shared.noteUsed(resolvedProfileID)
        navigationIntentCoordinator.host = self
        sessionHistoryCoordinator.host = self
        faviconCoordinator.host = self
        zoomCoordinator.host = self
        downloadActivityCoordinator.host = self

        // Set up navigation delegate
        let navDelegate = BrowserNavigationDelegate()
        navDelegate.openInNewTab = { [weak self] url in
            self?.openLinkInNewTab(url: url)
        }
        navDelegate.requestNavigation = { [weak self] request, intent in
            self?.navigationIntentCoordinator.requestNavigation(request, intent: intent)
        }
        navDelegate.presentAlert = { [weak self] alert, webView, completion, cancel in
            guard let self else {
                cancel()
                return
            }
            self.presentBrowserAlert(alert, in: webView, completion: completion, cancel: cancel)
        }
        navDelegate.shouldBlockInsecureHTTPNavigation = { [weak self] url in
            self?.navigationIntentCoordinator.shouldBlockInsecureHTTPNavigation(to: url) ?? false
        }
        navDelegate.shouldBlockInsecureHTTPSubframeDownload = { browserShouldBlockInsecureHTTPURL($0) }
        navDelegate.handleBlockedInsecureHTTPNavigation = { [weak self] request, intent in
            self?.presentInsecureHTTPAlert(for: request, intent: intent, recordTypedNavigation: false)
        }
        navDelegate.didTerminateWebContentProcess = { [weak self] webView in
            self?.replaceWebViewAfterContentProcessTermination(for: webView)
        }
        // Set up download delegate for navigation-based downloads.
        // Downloads save to a temp file synchronously (no UI during WebKit
        // callbacks), then auto-save to Downloads unless the prompt setting is enabled.
        let dlDelegate = BrowserDownloadDelegate()
        dlDelegate.savePanelParentWindow = { [weak self] in
            self.flatMap { browserInteractiveModalHostWindow(for: $0.webView) }
        }
        dlDelegate.onDownloadStarted = { [weak self] filename, downloadID in
            guard let self else { return }
            self.beginDownloadActivity()
            self.postBrowserDownloadEvent([
                "type": "started",
                "download_id": downloadID,
                "filename": filename
            ])
        }
        dlDelegate.onDownloadReadyToSave = { [weak self] filename, downloadID in
            guard let self else { return }
            self.endDownloadActivity()
            self.postBrowserDownloadEvent([
                "type": "ready_to_save",
                "download_id": downloadID,
                "filename": filename
            ])
        }
        dlDelegate.onDownloadSaved = { [weak self] filename, destinationURL, shouldEndActivity, downloadID in
            guard let self else { return }
            if shouldEndActivity { self.endDownloadActivity() }
            self.postBrowserDownloadEvent([
                "type": "saved",
                "download_id": downloadID,
                "filename": filename,
                "path": destinationURL.path
            ])
        }
        dlDelegate.onDownloadCancelled = { [weak self] filename, shouldEndActivity, downloadID in
            guard let self else { return }
            if shouldEndActivity { self.endDownloadActivity() }
            self.postBrowserDownloadEvent([
                "type": "cancelled",
                "download_id": downloadID,
                "filename": filename
            ])
        }
        dlDelegate.onDownloadFailed = { [weak self] _, shouldEndActivity, downloadID in
            guard let self else { return }
            if shouldEndActivity { self.endDownloadActivity() }
            var event: [String: Any] = [
                "type": "failed",
                "error": String(localized: "browser.download.error.generic", defaultValue: "Download failed")
            ]
            if let downloadID {
                event["download_id"] = downloadID
            }
            self.postBrowserDownloadEvent(event)
        }
        navDelegate.downloadDelegate = dlDelegate
        self.downloadDelegate = dlDelegate
        self.navigationDelegate = navDelegate

        // Set up UI delegate (handles cmd+click, target=_blank, and context menu)
        let browserUIDelegate = BrowserUIDelegate()
        browserUIDelegate.openInNewTab = { [weak self] url in
            guard let self else { return }
            self.openLinkInNewTab(url: url)
        }
        browserUIDelegate.requestNavigation = { [weak self] request, intent in
            self?.navigationIntentCoordinator.requestNavigation(request, intent: intent)
        }
        browserUIDelegate.presentAlert = { [weak self] alert, webView, completion, cancel in
            guard let self else {
                cancel()
                return
            }
            self.presentBrowserAlert(alert, in: webView, completion: completion, cancel: cancel)
        }
        browserUIDelegate.openPopup = { [weak self] configuration, windowFeatures in
            self?.createFloatingPopup(configuration: configuration, windowFeatures: windowFeatures)
        }
        browserUIDelegate.closeRequested = { [weak self] closedWebView in
            guard let self, self.isCurrentWebView(closedWebView) else { return }
#if DEBUG
            cmuxDebugLog("browser.webViewDidClose panel=\(self.id.uuidString.prefix(5))")
#endif
            self.webViewDidRequestClose?()
        }
        self.uiDelegate = browserUIDelegate

        bindWebView(webView)
        installDetachedDeveloperToolsWindowCloseObserver()
        installHiddenWebViewDiscardPolicyObserver()
        applyBrowserThemeModeIfNeeded()
        ReactGrabScriptLoader.prefetch()
        insecureHTTPAlertWindowProvider = { [weak self] in
            if let self, let window = browserInteractiveModalHostWindow(for: self.webView) {
                return window
            }
            return BrowserExternalNavigationPresenter.fallbackInteractiveModalHostWindow()
        }

        if let initialRequest {
            hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
            currentURL = initialRequest.url
            shouldRenderWebView = renderInitialNavigation
            guard renderInitialNavigation else { return }
            if let url = initialRequest.url,
               navigationIntentCoordinator.insecureHTTPBypassHostOnce == nil,
               navigationIntentCoordinator.shouldBlockInsecureHTTPNavigation(to: url) {
                presentInsecureHTTPAlert(
                    for: initialRequest,
                    intent: .currentTab,
                    recordTypedNavigation: false
                )
            } else {
                navigateWithoutInsecureHTTPPrompt(
                    request: initialRequest,
                    recordTypedNavigation: false
                )
            }
        } else if let url = initialURL {
            hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
            currentURL = url
            shouldRenderWebView = renderInitialNavigation
            guard renderInitialNavigation else { return }
            if adoptedPrewarmedWebView {
                // Already navigated while hidden; record for recovery paths.
                navigationDelegate?.recordAttemptedRequest(URLRequest(url: url), displayURL: url)
                refreshBackgroundAppearance()
            } else {
                navigate(to: url)
            }
        }
    }

    @discardableResult
    private func ensureBackgroundPreloadHostIfNeeded(reason: String) -> Bool {
        if let preloadWindow = backgroundPreloadWindow {
            guard webView.window == nil,
                  webView.superview == nil,
                  let contentView = preloadWindow.contentView else {
                return false
            }
            webView.frame = contentView.bounds
            webView.autoresizingMask = [.width, .height]
            contentView.addSubview(webView)
            return true
        }

        guard webView.window == nil else { return false }
        guard webView.superview == nil else { return false }

        let frame = NSRect(x: -10_000, y: -10_000, width: 800, height: 600)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserBackgroundPreload")
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isExcludedFromWindowsMenu = true

        let contentView = NSView(frame: frame)
        webView.frame = contentView.bounds
        webView.autoresizingMask = [.width, .height]
        contentView.addSubview(webView)
        window.contentView = contentView
        backgroundPreloadWindow = window
        window.orderFrontRegardless()

#if DEBUG
        cmuxDebugLog(
            "browser.backgroundPreload.host.create panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason)"
        )
#endif
        return true
    }

    private func shouldDeferPromptUntilInteractiveHost(for webView: WKWebView) -> Bool {
        if shouldPreloadInitialNavigationInBackground {
            return true
        }
        guard let preloadWindow = backgroundPreloadWindow else { return false }
        let attachedWindow = webView.window
        return attachedWindow == nil || attachedWindow === preloadWindow
    }

    private func presentBrowserAlert(
        _ alert: NSAlert,
        in webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void,
        cancel: @escaping () -> Void
    ) {
        if let window = browserInteractiveModalHostWindow(for: webView) {
            alert.beginSheetModal(for: window, completionHandler: completion)
            return
        }

        guard shouldDeferPromptUntilInteractiveHost(for: webView) else {
            browserPresentAlert(alert, in: webView, completion: completion, cancel: cancel)
            return
        }

        pendingInteractiveBrowserPrompts.append(
            PendingInteractiveBrowserPrompt(
                present: { sheetWindow, didFinish in
                    alert.beginSheetModal(for: sheetWindow) { response in
                        completion(response)
                        didFinish()
                    }
                },
                cancel: cancel
            )
        )

#if DEBUG
        cmuxDebugLog(
            "browser.prompt.queue panel=\(id.uuidString.prefix(5)) " +
            "pending=\(pendingInteractiveBrowserPrompts.count)"
        )
#endif
    }

    private func drainPendingInteractiveBrowserPromptsIfPossible(reason: String) {
        guard !isPresentingPendingInteractiveBrowserPrompt else { return }
        guard !pendingInteractiveBrowserPrompts.isEmpty else { return }
        guard let window = browserInteractiveModalHostWindow(for: webView) else { return }

        let prompt = pendingInteractiveBrowserPrompts.removeFirst()
        isPresentingPendingInteractiveBrowserPrompt = true

#if DEBUG
        cmuxDebugLog(
            "browser.prompt.drain panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) remaining=\(pendingInteractiveBrowserPrompts.count)"
        )
#endif

        prompt.present(window) { [weak self] in
            guard let self else { return }
            self.isPresentingPendingInteractiveBrowserPrompt = false
            self.drainPendingInteractiveBrowserPromptsIfPossible(reason: "\(reason).next")
        }
    }

    private func cancelPendingInteractiveBrowserPrompts(reason: String) {
        guard !pendingInteractiveBrowserPrompts.isEmpty else { return }
        let prompts = pendingInteractiveBrowserPrompts
        pendingInteractiveBrowserPrompts.removeAll()
        isPresentingPendingInteractiveBrowserPrompt = false

#if DEBUG
        cmuxDebugLog(
            "browser.prompt.cancel panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) count=\(prompts.count)"
        )
#endif

        prompts.forEach { $0.cancel() }
    }

    func releaseBackgroundPreloadHostIfAttachedToRealWindow(reason: String) {
        guard let preloadWindow = backgroundPreloadWindow else { return }
        guard let attachedWindow = webView.window else { return }
        guard attachedWindow !== preloadWindow else { return }
        closeBackgroundPreloadHost(reason: reason)
        drainPendingInteractiveBrowserPromptsIfPossible(reason: reason)
    }

    private func closeBackgroundPreloadHost(reason: String) {
        guard let preloadWindow = backgroundPreloadWindow else { return }
        backgroundPreloadWindow = nil
        preloadWindow.contentView = nil
        preloadWindow.close()
#if DEBUG
        cmuxDebugLog(
            "browser.backgroundPreload.host.close panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason)"
        )
#endif
    }

    func setRemoteProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {
        guard !bypassesRemoteWorkspaceProxy else { return }
        guard remoteProxyEndpoint != endpoint else { return }
        remoteProxyEndpoint = endpoint
        applyProxyConfigurationIfAvailable()
        resumePendingRemoteNavigationIfNeeded()
    }

    func setRemoteWorkspaceStatus(_ status: BrowserRemoteWorkspaceStatus?) {
        guard remoteWorkspaceStatus != status else { return }
        remoteWorkspaceStatus = status
    }

    private func applyProxyConfigurationIfAvailable() {
        guard #available(macOS 14.0, *) else { return }

        let store = webView.configuration.websiteDataStore
        guard let endpoint = remoteProxyEndpoint else {
            // Local panes mirror an active system proxy with loopback excluded
            // (#5888); remote panes keep [] while their endpoint is pending/lost.
            store.proxyConfigurations = usesRemoteWorkspaceProxy
                ? [] : BrowserSystemProxyMirror.currentProxyConfigurations()
            return
        }

        store.proxyConfigurations = BrowserRemoteProxyConnectionFactory().proxyConfigurations(for: endpoint)
    }

    private func beginDownloadActivity() {
        let apply = {
            self.downloadActivityCoordinator.begin()
        }
        if Thread.isMainThread {
            apply()
        } else {
            Task { @MainActor [weak self] in self?.downloadActivityCoordinator.begin() }
        }
    }

    private func endDownloadActivity() {
        let apply = {
            self.downloadActivityCoordinator.end()
        }
        if Thread.isMainThread {
            apply()
        } else {
            Task { @MainActor [weak self] in self?.downloadActivityCoordinator.end() }
        }
    }

    private func postBrowserDownloadEvent(_ event: [String: Any]) {
        NotificationCenter.default.post(
            name: .browserDownloadEventDidArrive,
            object: self,
            userInfo: [
                "surfaceId": id,
                "workspaceId": workspaceId,
                "event": event
            ]
        )
    }

    /// Publishes the download-active flag for ``BrowserDownloadActivityCoordinator``
    /// (writes the `@Published private(set) isDownloading`).
    func setDownloadingActive(_ active: Bool) {
        isDownloading = active
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func reattachToWorkspace(
        _ newWorkspaceId: UUID,
        isRemoteWorkspace: Bool,
        remoteWebsiteDataStoreIdentifier: UUID? = nil,
        proxyEndpoint: BrowserProxyEndpoint?,
        remoteStatus: BrowserRemoteWorkspaceStatus?
    ) {
        workspaceId = newWorkspaceId
        usesRemoteWorkspaceProxy = isRemoteWorkspace && !bypassesRemoteWorkspaceProxy
        let targetStore = isRemoteWorkspace
            ? WKWebsiteDataStore(forIdentifier: remoteWebsiteDataStoreIdentifier ?? newWorkspaceId)
            : BrowserProfileStore.shared.websiteDataStore(for: profileID)
        let needsStoreSwap = webView.configuration.websiteDataStore !== targetStore
        websiteDataStore = targetStore
        remoteProxyEndpoint = bypassesRemoteWorkspaceProxy ? nil : proxyEndpoint
        remoteWorkspaceStatus = remoteStatus
        if needsStoreSwap {
            replaceWebViewPreservingState(
                from: webView,
                websiteDataStore: targetStore,
                reason: "workspace_reattach"
            )
        }
        applyProxyConfigurationIfAvailable()
        resumePendingRemoteNavigationIfNeeded()
    }

    @discardableResult
    func switchToProfile(_ requestedProfileID: UUID) -> Bool {
        let resolvedProfileID = BrowserProfileStore.shared.profileDefinition(id: requestedProfileID) != nil
            ? requestedProfileID
            : BrowserProfileStore.shared.builtInDefaultProfileID
        guard resolvedProfileID != profileID else {
            BrowserProfileStore.shared.noteUsed(resolvedProfileID)
            return false
        }

        let previousWebView = webView
        let wasRenderable = shouldRenderWebView
        let restoreURL = previousWebView.url ?? currentURL
        let restoreURLString = restoreURL?.absoluteString
        let shouldRestoreURL = wasRenderable && restoreURLString != nil && restoreURLString != blankURLString
        let history = sessionNavigationHistorySnapshot()
        let historyCurrentURL = preferredURLStringForOmnibar()
        let desiredZoom = zoomPolicy.clamp(previousWebView.pageZoom)
        let restoreDeveloperTools = preferredDeveloperToolsVisible || isDeveloperToolsVisible()

        invalidateSearchFocusRequests(reason: "profileSwitch")
        searchState = nil

        _ = hideDeveloperTools()
        cancelDeveloperToolsRestoreRetry()

        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        clearWebContentTerminationRecovery()
        clearBrowserFocusMode(reason: "profileSwitch")
        faviconCoordinator.cancelInFlightRefreshInvalidatingGeneration()
        cancelPendingInteractiveBrowserPrompts(reason: "profileSwitch")
        closeBackgroundPreloadHost(reason: "profileSwitch")
        BrowserWindowPortalRegistry.detach(webView: previousWebView)
        webAuthnCoordinator.uninstall(from: previousWebView)
        previousWebView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
        previousWebView.navigationDelegate = nil
        previousWebView.uiDelegate = nil
        if let previousCmuxWebView = previousWebView as? CmuxWebView {
            previousCmuxWebView.onContextMenuDownloadStateChanged = nil
        }

        profileID = resolvedProfileID
        historyStore = BrowserProfileStore.shared.historyStore(for: resolvedProfileID)
        BrowserProfileStore.shared.noteUsed(resolvedProfileID)

        if !usesRemoteWorkspaceProxy {
            websiteDataStore = BrowserProfileStore.shared.websiteDataStore(for: resolvedProfileID)
        }

        let replacement = Self.makeWebView(
            profileID: resolvedProfileID,
            websiteDataStore: websiteDataStore
        )
        replacement.pageZoom = desiredZoom
        webViewInstanceID = UUID()
        resetWebViewLifecycleMetadata(resetVisibility: false)
        webView = replacement
        currentURL = restoreURL
        shouldRenderWebView = wasRenderable
        refreshWebViewLifecycleState()

        bindWebView(replacement)
        applyProxyConfigurationIfAvailable()
        applyBrowserThemeModeIfNeeded()

        if !history.backHistoryURLStrings.isEmpty || !history.forwardHistoryURLStrings.isEmpty {
            restoreSessionNavigationHistory(
                backHistoryURLStrings: history.backHistoryURLStrings,
                forwardHistoryURLStrings: history.forwardHistoryURLStrings,
                currentURLString: historyCurrentURL
            )
        }

        if shouldRestoreURL, let restoreURL {
            navigateWithoutInsecureHTTPPrompt(
                to: restoreURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true
            )
        } else {
            refreshNavigationAvailability()
        }

        if restoreDeveloperTools {
            requestDeveloperToolsRefreshAfterNextAttach(reason: "profile_switch")
        }

        return true
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationDefaultsToggle.paneFlash.isEnabled() else { return }
        focusFlashToken &+= 1
    }

    func sessionNavigationHistorySnapshot() -> (
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String]
    ) {
        let snapshot = sessionHistoryCoordinator.sessionNavigationHistorySnapshot()
        return (snapshot.backHistoryURLStrings, snapshot.forwardHistoryURLStrings)
    }

    /// Host primitive: the resolved live session-history URL (slice-1 resolver).
    func resolvedLiveSessionHistoryURL() -> URL? {
        if let displayURL = Self.restorableDisplayURL(
            liveURL: webView.url,
            currentURL: currentURL,
            activeErrorPageDisplayURL: navigationDelegate?.activeErrorPageDisplayURL
        ),
            Self.serializableSessionHistoryURLString(displayURL) != nil {
            return displayURL
        }
        return Self.sessionHistoryURLResolver.resolvedLiveURL(
            webViewDisplayURL: BrowserRemoteProxyURLRewriter.displayURL(for: webView.url),
            currentURL: currentURL
        )
    }

    private func realignRestoredSessionHistoryToLiveCurrentIfPossible() {
        sessionHistoryCoordinator.realignToLiveCurrentIfPossible()
    }

    func restoreSessionNavigationHistory(
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String],
        currentURLString: String?
    ) {
        sessionHistoryCoordinator.restoreSessionNavigationHistory(
            backHistoryURLStrings: backHistoryURLStrings,
            forwardHistoryURLStrings: forwardHistoryURLStrings,
            currentURLString: currentURLString
        )
    }

    func restoreSessionSnapshot(_ snapshot: SessionBrowserPanelSnapshot) {
        // Diff viewer surfaces re-register their token from the on-disk manifest
        // and navigate via the app-owned custom scheme, so they restore even
        // though the local HTTP server that originally served them is gone.
        if let token = snapshot.diffViewerToken,
           let requestPath = snapshot.diffViewerRequestPath,
           CmuxDiffViewerURLSchemeHandler.shared.registerFromManifest(token: token),
           let diffURL = CmuxDiffViewerURLSchemeHandler.diffViewerURL(token: token, requestPath: requestPath) {
            hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(snapshot.shouldRenderWebView)
            setMuted(snapshot.isMuted)
            setOmnibarVisible(snapshot.omnibarVisible ?? false)
            currentURL = diffURL
            let shouldRenderRestoredWebView = snapshot.shouldRenderWebView && BrowserAvailabilitySettings.isEnabled()
            guard shouldRenderRestoredWebView else {
                shouldRenderWebView = false
                refreshNavigationAvailability()
                return
            }
            deferRestoredWebViewLoadUntilVisible(url: diffURL, reason: "session_restore.diff")
            return
        }

        let restoredURL = Self.remappedAppPricingSessionRestoreURL(Self.sanitizedSessionHistoryURL(snapshot.urlString))
        let shouldRenderRestoredWebView = snapshot.shouldRenderWebView && BrowserAvailabilitySettings.isEnabled()
        hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(snapshot.shouldRenderWebView)
        setMuted(snapshot.isMuted)
        setOmnibarVisible(snapshot.omnibarVisible ?? true)

        restoreSessionNavigationHistory(
            backHistoryURLStrings: snapshot.backHistoryURLStrings ?? [],
            forwardHistoryURLStrings: snapshot.forwardHistoryURLStrings ?? [],
            currentURLString: restoredURL?.absoluteString ?? snapshot.urlString
        )

        currentURL = restoredURL

        guard shouldRenderRestoredWebView, let restoredURL else {
            shouldRenderWebView = false
            refreshNavigationAvailability()
            return
        }

        deferRestoredWebViewLoadUntilVisible(url: restoredURL, reason: "session_restore")
    }

    private func deferRestoredWebViewLoadUntilVisible(url: URL, reason: String) {
        currentURL = url
        shouldRenderWebView = false
        hiddenWebViewDiscardManager.markDiscarded(reason: reason, now: Date())
        refreshNavigationAvailability()
        refreshWebViewLifecycleState()
    }

    func shouldRenderWebViewForSessionSnapshot() -> Bool {
        guard Self.sessionHistoryURLResolver.sessionSnapshotIsRenderable(
            preferredURLString: preferredURLStringForSessionSnapshot(),
            hasDiffViewerComponents: diffViewerSessionComponents() != nil
        ) else {
            return false
        }
        return hiddenWebViewDiscardManager.restoredSessionShouldRenderWebView ?? shouldRenderWebView
    }

    func shouldPersistSessionSnapshot() -> Bool {
        let diffViewerRestorable = diffViewerSessionComponents().map { components in
            CmuxDiffViewerURLSchemeHandler.shared.diffViewerRestorable(
                token: components.token,
                requestPath: components.requestPath
            )
        }
        return Self.sessionHistoryURLResolver.shouldPersistSessionSnapshot(
            diffViewerRestorable: diffViewerRestorable,
            webViewURL: webView.url,
            currentURL: currentURL,
            restoredCurrentURL: restoredHistoryCurrentURL
        )
    }

    /// Whether this surface is transparent internal cmux UI, for the session
    /// snapshot (so it restores transparent rather than opaque).
    var sessionSnapshotTransparentBackground: Bool {
        usesTransparentBackground
    }

    /// The diff viewer `(token, requestPath)` for the live URL, if this surface
    /// is currently showing a diff viewer; used to persist + restore it.
    func diffViewerSessionComponents() -> (token: String, requestPath: String)? {
        CmuxDiffViewerURLSchemeHandler.diffViewerComponents(from: webView.url)
            ?? CmuxDiffViewerURLSchemeHandler.diffViewerComponents(from: currentURL)
    }

    func preferredURLStringForSessionSnapshot() -> String? {
        if let displayURL = Self.restorableDisplayURL(
            liveURL: webView.url,
            currentURL: currentURL,
            activeErrorPageDisplayURL: navigationDelegate?.activeErrorPageDisplayURL
        ),
            let value = Self.serializableSessionHistoryURLString(displayURL) {
            return value
        }
        return Self.sessionHistoryURLResolver.preferredURLString(
            webViewDisplayURL: BrowserRemoteProxyURLRewriter.displayURL(for: webView.url),
            currentURL: currentURL
        )
    }

    private func setupObservers(for webView: WKWebView) {
        let observedWebViewInstanceID = webViewInstanceID

        // URL changes
        let urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, change in
            let observedURL = change.newValue ?? webView.url
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                guard !self.isMainFrameProvisionalNavigationActive else { return }
                self.currentURL = BrowserRemoteProxyURLRewriter.displayURL(for: observedURL)
                self.refreshBackgroundAppearance()
                GlobalSearchCoordinator.shared.captureBrowserPanel(self)
            }
        }
        webViewObservers.append(urlObserver)

        // Title changes
        let titleObserver = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                // Keep showing the last non-empty title while the new navigation is loading.
                // WebKit often clears title to nil/"" during reload/navigation, which causes
                // a distracting tab-title flash (e.g. to host/URL). Only accept non-empty titles.
                let trimmed = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.pageTitle = trimmed
                GlobalSearchCoordinator.shared.captureBrowserPanel(self)
            }
        }
        webViewObservers.append(titleObserver)

        // Loading state
        // Capture the KVO-provided value at observation time rather than reading
        // webView.isLoading inside the deferred Task. For fast navigations (e.g.
        // back-forward cache), isLoading can flip true→false before the first Task
        // runs, causing handleWebViewLoadingChanged(true) to be missed entirely.
        // That skips favicon/loading-state cleanup and leaves stale icons visible.
        let loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, change in
            let newValue = change.newValue ?? webView.isLoading
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.handleWebViewLoadingChanged(newValue)
            }
        }
        webViewObservers.append(loadingObserver)

        // Can go back
        let backObserver = webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.nativeCanGoBack = webView.canGoBack
                self.refreshNavigationAvailability()
            }
        }
        webViewObservers.append(backObserver)

        // Can go forward
        let forwardObserver = webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.nativeCanGoForward = webView.canGoForward
                self.refreshNavigationAvailability()
            }
        }
        webViewObservers.append(forwardObserver)

        // Progress
        let progressObserver = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.estimatedProgress = webView.estimatedProgress
            }
        }
        webViewObservers.append(progressObserver)

        let fullscreenObserver = webView.observe(\.fullscreenState, options: [.initial, .new]) { [weak self] webView, _ in
            let isElementFullscreenActive = webView.cmuxIsElementFullscreenActiveOrTransitioning
            let fullscreenState = webView.fullscreenState
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                let didChangeFullscreenBlocker = self.isElementFullscreenActive != isElementFullscreenActive
                self.isElementFullscreenActive = isElementFullscreenActive
                if didChangeFullscreenBlocker {
                    self.reevaluateHiddenWebViewDiscardScheduling(reason: "fullscreen_changed")
                }
                BrowserWindowPortalRegistry.refresh(
                    webView: webView,
                    reason: "fullscreenStateChanged"
                )
#if DEBUG
                cmuxDebugLog(
                    "browser.fullscreen.state panel=\(self.id.uuidString.prefix(5)) " +
                    "web=\(ObjectIdentifier(webView)) state=\(String(describing: fullscreenState)) " +
                    "active=\(isElementFullscreenActive ? 1 : 0)"
                )
#endif
            }
        }
        webViewObservers.append(fullscreenObserver)

        let cameraCaptureObserver = webView.observe(\.cameraCaptureState, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.reevaluateHiddenWebViewDiscardScheduling(reason: "media_capture_changed")
            }
        }
        webViewObservers.append(cameraCaptureObserver)

        let microphoneCaptureObserver = webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.reevaluateHiddenWebViewDiscardScheduling(reason: "media_capture_changed")
            }
        }
        webViewObservers.append(microphoneCaptureObserver)

        NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)
            .sink { [weak self] notification in
                guard let self else { return }
                self.applyWebViewBackground(color: GhosttyBackgroundTheme.color(from: notification))
            }
            .store(in: &webViewCancellables)

        // Keep the local-workspace system-proxy mirror fresh when the user
        // toggles a global proxy or switches network locations mid-session.
        NotificationCenter.default.publisher(for: .browserSystemProxySettingsDidChange)
            .sink { [weak self] _ in self?.applyProxyConfigurationIfAvailable() }
            .store(in: &webViewCancellables)

        // Apply the configured background for the freshly bound webview (covers
        // the initial bind and every post-crash replacement).
        applyConfiguredWebViewBackground()
    }

    /// Configures the live webview's background for the current Ghostty theme.
    private func applyConfiguredWebViewBackground() {
        applyWebViewBackground(color: GhosttyBackgroundTheme.currentColor())
    }

    private func refreshBackgroundAppearance() {
        applyConfiguredWebViewBackground()
        backgroundAppearanceRevision &+= 1
    }

    /// Applies the webview background for a given terminal theme color.
    ///
    /// When Ghostty transparency/glass makes the window root own the terminal
    /// backdrop, clear the browser's native fill for blank pages. Real websites
    /// keep WebKit's background drawing so pages without their own CSS
    /// background remain readable.
    private func applyWebViewBackground(color: NSColor) {
        if !drawsConfiguredWebViewBackgroundForCurrentPage() {
            webView.wantsLayer = true
            webView.setValue(false, forKey: "drawsBackground")
            webView.underPageBackgroundColor = .clear
            webView.layer?.isOpaque = false
            webView.layer?.backgroundColor = NSColor.clear.cgColor
            portalAnchorView.wantsLayer = true
            portalAnchorView.layer?.isOpaque = false
            portalAnchorView.layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        if usesTransparentBackground {
            // Transparent-background internal surface (the diff viewer, and future
            // app-bundled cmux panels) on an OPAQUE theme. The page keeps its body
            // transparent, and the pane behind it is a plain gray window backdrop,
            // not the terminal color. With WebKit drawing its own background the
            // webview flashes white during navigation (blank document) and any
            // transparent page region (loading skeleton, empty/error state) shows
            // gray. So instead of letting WebKit draw, paint the webview and its
            // portal anchor with the theme color directly (clear-draw + themed
            // layer, exactly like the markdown and agent-session renderers). That
            // makes the blank webview, the brief pane-reveal frame, and every
            // transparent page region render the terminal color from the first
            // frame. Tracks live theme changes via this same call.
            webView.wantsLayer = true
            webView.setValue(false, forKey: "drawsBackground")
            webView.underPageBackgroundColor = color
            webView.layer?.isOpaque = color.alphaComponent >= 0.999
            webView.layer?.backgroundColor = color.cgColor
            portalAnchorView.wantsLayer = true
            portalAnchorView.layer?.isOpaque = color.alphaComponent >= 0.999
            portalAnchorView.layer?.backgroundColor = color.cgColor
            return
        }
        // Real website on an opaque theme: keep WebKit drawing its own background
        // so pages without their own CSS background remain readable. (Restores
        // opaque drawing in case a transparent theme previously made this webview
        // clear before the user switched to an opaque theme.)
        webView.setValue(true, forKey: "drawsBackground")
        webView.layer?.isOpaque = color.alphaComponent >= 0.999
        webView.layer?.backgroundColor = nil
        webView.underPageBackgroundColor = color
        portalAnchorView.wantsLayer = true
        portalAnchorView.layer?.isOpaque = false
        portalAnchorView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    func drawsConfiguredWebViewBackgroundForCurrentPage() -> Bool {
        Self.drawsConfiguredWebViewBackground(
            isBlankPage: isShowingBlankBrowserPage,
            usesTransparentBackground: usesTransparentBackground
        )
    }

    /// Whether browser native/SwiftUI fills should draw over the window root
    /// backdrop. Mirrors terminal/markdown panel background decisions.
    static func drawsConfiguredWebViewBackground(
        isBlankPage: Bool,
        usesTransparentBackground: Bool = false
    ) -> Bool {
        drawsWebViewBackground(
            isBlankPage: isBlankPage,
            usesTransparentBackground: usesTransparentBackground,
            opacity: GhosttyApp.shared.defaultBackgroundOpacity,
            usesGhosttyGlassStyle: GhosttyApp.shared.defaultBackgroundBlur.isMacOSGlassStyle,
            usesTransparentWindow: WindowBackgroundComposition.policy
                .shouldUseTransparentBackgroundWindow(glassEffectAvailable: false)
        )
    }

    nonisolated static func isBlankBrowserPageURL(_ url: URL?) -> Bool {
        guard let url else { return true }
        let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.caseInsensitiveCompare("about:blank") == .orderedSame
    }

    nonisolated static func isBlankBrowserPage(
        liveURL: URL?,
        currentURL: URL?,
        pendingNavigationURL: URL?,
        isMainFrameProvisionalNavigationActive: Bool
    ) -> Bool {
        if isMainFrameProvisionalNavigationActive,
           !isBlankBrowserPageURL(pendingNavigationURL) {
            return false
        }
        if !isBlankBrowserPageURL(pendingNavigationURL),
           isBlankBrowserPageURL(liveURL),
           isBlankBrowserPageURL(currentURL) {
            return false
        }
        return isBlankBrowserPageURL(liveURL) && isBlankBrowserPageURL(currentURL)
    }

    nonisolated static func drawsWebViewBackground(
        isBlankPage: Bool,
        usesTransparentBackground: Bool = false,
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        if usesTransparentBackground {
            return drawsWebViewBackground(
                opacity: opacity,
                usesGhosttyGlassStyle: usesGhosttyGlassStyle,
                usesTransparentWindow: usesTransparentWindow
            )
        }
        guard isBlankPage else { return true }
        return drawsWebViewBackground(
            opacity: opacity,
            usesGhosttyGlassStyle: usesGhosttyGlassStyle,
            usesTransparentWindow: usesTransparentWindow
        )
    }

    nonisolated static func drawsWebViewBackground(
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        !PanelAppearance.shouldUseClearContentBackground(
            opacity: opacity,
            usesGhosttyGlassStyle: usesGhosttyGlassStyle,
            usesTransparentWindow: usesTransparentWindow
        )
    }

    private func replaceWebViewAfterContentProcessTermination(for terminatedWebView: WKWebView) {
        replaceWebViewPreservingState(
            from: terminatedWebView,
            websiteDataStore: websiteDataStore,
            reason: "webcontent_process_terminated",
            waitForManualRecovery: true
        )
    }

    private func replaceWebViewPreservingState(
        from oldWebView: WKWebView,
        websiteDataStore: WKWebsiteDataStore,
        reason: String,
        waitForManualRecovery: Bool = false
    ) {
        guard oldWebView === webView else { return }

        let wasRenderable = shouldRenderWebView
        let attemptedURL = BrowserRemoteProxyURLRewriter.displayURL(for: navigationDelegate?.lastAttemptedURL)
            ?? navigationDelegate?.lastAttemptedURL
        let liveURL = Self.restorableDisplayURL(
            liveURL: oldWebView.url,
            currentURL: currentURL,
            activeErrorPageDisplayURL: navigationDelegate?.activeErrorPageDisplayURL
        )
        let restoreURL = (isMainFrameProvisionalNavigationActive ? attemptedURL : nil)
            ?? liveURL
            ?? attemptedURL
            ?? resolvedCurrentSessionHistoryURL()
        let restoreURLString = restoreURL?.absoluteString
        let hasRecoveryTarget = restoreURLString != nil && restoreURLString != blankURLString
        let shouldRestoreURL = wasRenderable && hasRecoveryTarget
        let shouldShowManualRecovery = waitForManualRecovery && wasRenderable && hasRecoveryTarget
        let history = sessionNavigationHistorySnapshot()
        let historyCurrentURL = preferredURLStringForOmnibar()
        let desiredZoom = zoomPolicy.clamp(oldWebView.pageZoom)
        let restoreDevTools = preferredDeveloperToolsVisible

#if DEBUG
        cmuxDebugLog(
            "browser.webview.replace.begin panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) " +
            "renderable=\(wasRenderable ? 1 : 0) restoreURL=\(restoreURLString ?? "nil") " +
            "restoreHistoryBack=\(history.backHistoryURLStrings.count) " +
            "restoreHistoryForward=\(history.forwardHistoryURLStrings.count)"
        )
#endif

        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        clearBrowserFocusMode(reason: reason)
        faviconCoordinator.cancelInFlightRefreshInvalidatingGeneration()
        loadingGeneration &+= 1
        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil
        isLoading = false
        estimatedProgress = 0
        cancelPendingInteractiveBrowserPrompts(reason: reason)
        closeBackgroundPreloadHost(reason: reason)
        BrowserWindowPortalRegistry.detach(webView: oldWebView)
        webAuthnCoordinator.uninstall(from: oldWebView)
        oldWebView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
        oldWebView.navigationDelegate = nil
        oldWebView.uiDelegate = nil
        if let oldCmuxWebView = oldWebView as? CmuxWebView {
            oldCmuxWebView.onContextMenuDownloadStateChanged = nil
        }

        let replacement = Self.makeWebView(
            profileID: profileID,
            websiteDataStore: websiteDataStore
        )
        replacement.pageZoom = desiredZoom
        webViewInstanceID = UUID()
        resetWebViewLifecycleMetadata(resetVisibility: false)
        webView = replacement
        shouldRenderWebView = wasRenderable
        refreshWebViewLifecycleState()

        bindWebView(replacement)
        applyBrowserThemeModeIfNeeded()

        if !history.backHistoryURLStrings.isEmpty || !history.forwardHistoryURLStrings.isEmpty {
            restoreSessionNavigationHistory(
                backHistoryURLStrings: history.backHistoryURLStrings,
                forwardHistoryURLStrings: history.forwardHistoryURLStrings,
                currentURLString: historyCurrentURL
            )
        }

        if shouldShowManualRecovery, let restoreURL {
            pendingWebContentRecoveryURL = restoreURL
            hasRecoverableWebContentTermination = true
            refreshNavigationAvailability()
        } else {
            clearWebContentTerminationRecovery()
            if shouldRestoreURL, let restoreURL {
                navigateWithoutInsecureHTTPPrompt(
                    to: restoreURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: true
                )
            } else {
                refreshNavigationAvailability()
            }
        }

        if restoreDevTools {
            requestDeveloperToolsRefreshAfterNextAttach(reason: reason)
        }

#if DEBUG
        cmuxDebugLog(
            "browser.webview.replace.end panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) " +
            "instance=\(webViewInstanceID.uuidString.prefix(6)) " +
            "restoreURL=\(restoreURLString ?? "nil") shouldRestore=\(shouldRestoreURL ? 1 : 0)"
        )
#endif
    }

    @discardableResult
    func recoverTerminatedWebContent(
        reason: String = "manual",
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) -> Bool {
        guard hasRecoverableWebContentTermination else { return false }
        let recoveryURL = pendingWebContentRecoveryURL
        clearWebContentTerminationRecovery()
#if DEBUG
        cmuxDebugLog(
            "browser.webcontent.recover panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) url=\(recoveryURL?.absoluteString ?? "nil")"
        )
#endif
        guard let recoveryURL else {
            refreshNavigationAvailability()
            return true
        }
        navigateWithoutInsecureHTTPPrompt(
            to: recoveryURL,
            recordTypedNavigation: false,
            preserveRestoredSessionHistory: true,
            cachePolicy: cachePolicy
        )
        return true
    }

    private func clearWebContentTerminationRecovery() {
        pendingWebContentRecoveryURL = nil
        hasRecoverableWebContentTermination = false
    }

#if DEBUG
    func debugSimulateWebContentProcessTermination() {
        replaceWebViewAfterContentProcessTermination(for: webView)
    }
#endif

    // MARK: - Panel Protocol

    func focus() {
        if shouldSuppressWebViewFocus() {
            return
        }

        guard let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }

        // If nothing meaningful is loaded yet, prefer letting the omnibar take focus.
        if !webView.isLoading {
            let urlString = BrowserRemoteProxyURLRewriter.displayURL(for: webView.url)?.absoluteString ?? currentURL?.absoluteString
            if urlString == nil || urlString == "about:blank" {
                return
            }
        }

        if Self.responderChainContains(window.firstResponder, target: webView) {
            noteWebViewFocused()
            return
        }
        if window.makeFirstResponder(webView) {
            noteWebViewFocused()
        }
    }

    @discardableResult
    func requestExplicitWebViewFocus() -> Bool {
        // Programmatic WebView focus should win over stale omnibar focus state, especially
        // after workspace switches where the blank-page omnibar auto-focus can re-trigger.
        endSuppressWebViewFocusForAddressBar()
        clearWebViewFocusSuppression()
        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: id)

        guard let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return false }

        if Self.responderChainContains(window.firstResponder, target: webView) {
            // Prevent omnibar auto-focus from immediately stealing first responder back.
            suppressOmnibarAutofocus(for: 1.5)
            noteWebViewFocused()
            return true
        }

        guard window.makeFirstResponder(webView) else { return false }
        // Prevent omnibar auto-focus from immediately stealing first responder back.
        suppressOmnibarAutofocus(for: 1.5)
        noteWebViewFocused()

        DispatchQueue.main.async { [weak self, weak window, weak webView] in
            guard let self, let window, let webView else { return }
            guard webView.window === window else { return }
            if !Self.responderChainContains(window.firstResponder, target: webView),
               window.makeFirstResponder(webView) {
                self.suppressOmnibarAutofocus(for: 1.5)
                self.noteWebViewFocused()
            }
        }

        return true
    }

    func unfocus() {
        clearBrowserFocusMode(reason: "panelUnfocus")
        invalidateSearchFocusRequests(reason: "panelUnfocus")
        guard let window = webView.window else { return }
        if BrowserWindowPortalRegistry.yieldSearchOverlayFocusIfOwned(by: id, in: window) {
            return
        }
        if Self.responderChainContains(window.firstResponder, target: webView) {
            window.makeFirstResponder(nil)
        }
    }

    func close() {
        cancelHiddenWebViewDiscard()
        isClosingWebViewLifecycle = true
        refreshWebViewLifecycleState()
        GlobalSearchCoordinator.shared.purgePanel(id: id)
        closeDeveloperToolsForTeardown()

        // Ensure we don't keep a hidden WKWebView (or its content view) as first responder while
        // bonsplit/SwiftUI reshuffles views during close.
        unfocus()
        BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: nil)
        BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: nil)
        BrowserWindowPortalRegistry.detach(webView: webView)
        navigationDelegate?.cancelPendingAuthenticationPrompts()
        cancelPendingInteractiveBrowserPrompts(reason: "close")
        closeBackgroundPreloadHost(reason: "close")

        // Snapshot first: popup close unregisters itself from popupControllers.
        let popupsToClose = popupControllers
        popupControllers.removeAll()

        // Close all owned popup windows before tearing down delegates
        for popup in popupsToClose {
            popup.closeAllChildPopups()
            popup.closePopup()
        }

        webAuthnCoordinator.uninstall(from: webView)
        webView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if let cmuxWebView = webView as? CmuxWebView { cmuxWebView.clearBrowserDownloadCallbacks() }
        navigationDelegate = nil
        uiDelegate = nil
        webViewDidRequestClose = nil
        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        faviconCoordinator.cancelInFlightRefresh()
    }

    // MARK: - Popup window management

    func createFloatingPopup(
        configuration: WKWebViewConfiguration,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let controller = BrowserPopupWindowController(
            configuration: configuration,
            windowFeatures: windowFeatures,
            browserContext: popupBrowserContext,
            openerPanel: self
        )
        popupControllers.append(controller)
        reevaluateHiddenWebViewDiscardScheduling(reason: "popup_opened")
        return controller.webView
    }

    func removePopupController(_ controller: BrowserPopupWindowController) {
        popupControllers.removeAll { $0 === controller }
        reevaluateHiddenWebViewDiscardScheduling(reason: "popup_closed")
    }

    // The favicon-refresh state machine (refresh generation/sequencing, the SPA
    // retry-once, and the skip-cached-URL flow) moved to
    // CmuxBrowser.BrowserFaviconCoordinator. The host primitives below
    // (BrowserFaviconHosting) keep the live WKWebView read, the JS evaluation, the
    // remote-proxy URLSession, and the `@Published` faviconPNGData app-side as the
    // witness the coordinator forwards through.

    /// The current page URL the favicon refresh runs against (host primitive).
    var currentFaviconPageURL: URL? { webView.url }

    /// The current web view instance id, captured at refresh start (host primitive).
    var currentFaviconWebViewInstanceID: UUID { webViewInstanceID }

    /// Whether the captured `instanceID` still matches the live web view (host
    /// primitive; legacy `isCurrentWebView(webView, instanceID:)`).
    func isCurrentFaviconWebView(instanceID: UUID) -> Bool {
        isCurrentWebView(webView, instanceID: instanceID)
    }

    /// Evaluates the favicon discovery script in the live web view and returns the
    /// raw `href` (host primitive; the live `evaluateJavaScript` stays app-side).
    func evaluateFaviconDiscoveryScript() async -> String? {
        await evaluateJavaScriptString(
            BrowserFaviconDiscoveryScript.source,
            in: webView,
            timeoutNanoseconds: 400_000_000
        )
    }

    /// Whether a favicon PNG is already published (host primitive for skip-cached).
    var hasFaviconPNGData: Bool { faviconPNGData != nil }

    /// Fetches favicon bytes, applying the remote-proxy rewrite and session
    /// selection; returns `nil` on error (host primitive). The live proxy session
    /// stays app-side.
    func fetchFaviconData(request: URLRequest) async -> (Data, URLResponse)? {
        let effectiveRequest = remoteProxyPreparedRequest(from: request, logScope: "faviconRewrite")
        do {
            let remoteSession = remoteProxyURLSession()
            defer { remoteSession?.finishTasksAndInvalidate() }
            if let remoteSession {
#if DEBUG
                cmuxDebugLog(
                    "browser.favicon.fetch " +
                    "panel=\(id.uuidString.prefix(5)) " +
                    "via=proxy " +
                    "url=\(effectiveRequest.url?.absoluteString ?? "<nil>")"
                )
#endif
                return try await remoteSession.data(for: effectiveRequest)
            } else {
#if DEBUG
                cmuxDebugLog(
                    "browser.favicon.fetch " +
                    "panel=\(id.uuidString.prefix(5)) " +
                    "via=direct " +
                    "url=\(effectiveRequest.url?.absoluteString ?? "<nil>")"
                )
#endif
                return try await URLSession.shared.data(for: effectiveRequest)
            }
        } catch {
#if DEBUG
            cmuxDebugLog(
                "browser.favicon.fetchError " +
                "panel=\(id.uuidString.prefix(5)) " +
                "error=\(String(describing: error))"
            )
#endif
            return nil
        }
    }

    /// Publishes the rendered favicon PNG (host primitive; sets `@Published`
    /// `faviconPNGData`).
    func publishFaviconPNG(_ png: Data) {
        faviconPNGData = png
    }

    @MainActor
    private func evaluateJavaScriptString(
        _ script: String,
        in webView: WKWebView,
        timeoutNanoseconds: UInt64
    ) async -> String? {
        await withCheckedContinuation { continuation in
            var hasResumed = false

            func resume(_ value: String?) {
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: value)
            }

            webView.evaluateJavaScript(script) { result, _ in
                let value = result as? String
                Task { @MainActor in
                    resume(value)
                }
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                resume(nil)
            }
        }
    }

    private func handleWebViewLoadingChanged(_ newValue: Bool) {
        if newValue {
            cancelHiddenWebViewDiscard()
            // Any new load invalidates older favicon fetches, even for same-URL reloads.
            faviconCoordinator.invalidateRefreshForNewLoad()
            // Clear the previous page's favicon so it never persists across navigations.
            // The loading spinner covers this gap; didFinish will fetch the new favicon.
            faviconPNGData = nil
            loadingGeneration &+= 1
            loadingEndWorkItem?.cancel()
            loadingEndWorkItem = nil
            loadingStartedAt = Date()
            isLoading = true
            return
        }

        let genAtEnd = loadingGeneration
        let startedAt = loadingStartedAt ?? Date()
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = max(0, minLoadingIndicatorDuration - elapsed)

        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil

        if remaining <= 0.0001 {
            isLoading = false
            scheduleHiddenWebViewDiscardIfNeeded(reason: "load.finished")
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // If loading restarted, ignore this end.
            guard self.loadingGeneration == genAtEnd else { return }
            // If WebKit is still loading, ignore.
            guard !self.webView.isLoading else { return }
            self.isLoading = false
            self.scheduleHiddenWebViewDiscardIfNeeded(reason: "load.finished")
        }
        loadingEndWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    // MARK: - Navigation

    /// Navigate to a URL. Forwards to the navigation coordinator, which owns the
    /// insecure-HTTP prompt decision and the remote-proxy navigation queue.
    func navigate(to url: URL, recordTypedNavigation: Bool = false) {
        navigationIntentCoordinator.navigate(to: url, recordTypedNavigation: recordTypedNavigation)
    }

    private func navigateWithoutInsecureHTTPPrompt(
        to url: URL,
        recordTypedNavigation: Bool,
        preserveRestoredSessionHistory: Bool = false,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) {
        navigationIntentCoordinator.navigateWithoutInsecureHTTPPrompt(
            to: url,
            recordTypedNavigation: recordTypedNavigation,
            preserveRestoredSessionHistory: preserveRestoredSessionHistory,
            cachePolicy: cachePolicy
        )
    }

    private func navigateWithoutInsecureHTTPPrompt(
        request: URLRequest,
        recordTypedNavigation: Bool,
        preserveRestoredSessionHistory: Bool = false
    ) {
        navigationIntentCoordinator.navigateWithoutInsecureHTTPPrompt(
            request: request,
            recordTypedNavigation: recordTypedNavigation,
            preserveRestoredSessionHistory: preserveRestoredSessionHistory
        )
    }

    private func resumePendingRemoteNavigationIfNeeded() {
        navigationIntentCoordinator.resumePendingRemoteNavigationIfNeeded()
    }

    func performNavigation(
        request: URLRequest,
        originalURL: URL,
        recordTypedNavigation: Bool,
        preserveRestoredSessionHistory: Bool
    ) {
        cancelHiddenWebViewDiscard()
        clearWebContentTerminationRecovery()
        if !preserveRestoredSessionHistory {
            abandonRestoredSessionHistoryIfNeeded()
        }
        let effectiveRequest = remoteProxyPreparedRequest(from: request, logScope: "rewrite")
        // Some installs can end up with a legacy Chrome UA override; keep this pinned.
        webView.customUserAgent = String.safariDesktopUserAgent
        hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
        navigationDelegate?.lastAttemptedURL = originalURL
        refreshBackgroundAppearance()
        shouldRenderWebView = true
        if shouldPreloadInitialNavigationInBackground {
            shouldPreloadInitialNavigationInBackground = false
            ensureBackgroundPreloadHostIfNeeded(reason: "initial-navigation")
        }
        if recordTypedNavigation {
            historyStore.recordTypedNavigation(url: originalURL)
        }
        webView.browserLoadRequest(effectiveRequest)
    }

    private func remoteProxyPreparedRequest(from request: URLRequest, logScope: String) -> URLRequest {
        guard remoteProxyEndpoint != nil else { return request }
        guard let url = request.url else { return request }
        guard let rewrittenURL = BrowserRemoteProxyURLRewriter.loopbackAliasURL(for: url) else { return request }

        var rewrittenRequest = request
        rewrittenRequest.url = rewrittenURL
#if DEBUG
        cmuxDebugLog(
            "browser.remoteProxy.\(logScope) " +
            "panel=\(id.uuidString.prefix(5)) " +
            "from=\(url.absoluteString) " +
            "to=\(rewrittenURL.absoluteString)"
        )
#endif
        return rewrittenRequest
    }

    private func remoteProxyURLSession() -> URLSession? {
        guard let endpoint = remoteProxyEndpoint else { return nil }
        return BrowserRemoteProxyConnectionFactory().urlSession(for: endpoint)
    }

    /// Navigate with smart URL/search detection. Forwards to the navigation
    /// coordinator, which resolves a navigable URL or builds a search request.
    func navigateSmart(_ input: String) {
        navigationIntentCoordinator.navigateSmart(input)
    }

    func resolveNavigableURL(from input: String) -> URL? {
        navigationIntentCoordinator.resolveNavigableURL(from: input)
    }

    // The navigation decision and dispatch (insecure-HTTP block/one-time-bypass
    // policy, requestNavigation routing, the alert-response decision, the
    // remote-proxy navigation queue, and smart URL/search dispatch) moved to
    // CmuxBrowser.BrowserNavigationIntentCoordinator. The methods below are the
    // app-side host primitives (BrowserNavigationHosting) the coordinator
    // forwards effects through; the live NSAlert builder, the WKWebView load, and
    // the discard/render state stay here as the witness so the alert's
    // String(localized:) strings bind to the app bundle and the live WebKit state
    // stays app-side.

    /// Whether the remote-workspace proxy endpoint is available yet (host
    /// primitive; read-through of `remoteProxyEndpoint`).
    var hasRemoteProxyEndpoint: Bool { remoteProxyEndpoint != nil }

    /// Resets the hidden-web-view discard state before a navigation begins (host
    /// primitive).
    func prepareWebViewDiscardStateForNavigation() {
        cancelHiddenWebViewDiscard()
        clearWebViewDiscardState(reason: "navigation")
    }

    /// Sets the URL shown for the current surface while a navigation is queued
    /// behind a remote-proxy endpoint (host primitive).
    func setCurrentDisplayURL(_ url: URL) {
        currentURL = url
    }

    /// Applies the placeholder render intent for a navigation queued behind a
    /// pending remote-proxy endpoint (host primitive).
    func setRenderIntent(forQueuedRemoteNavigationAttempting url: URL) {
        hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
        navigationDelegate?.lastAttemptedURL = url
        refreshBackgroundAppearance()
        shouldRenderWebView = true
    }

    /// Loads `request` in the current tab's web view without re-running the
    /// insecure-HTTP prompt (host primitive for the navigation-intent coordinator).
    func loadRequestInCurrentTab(_ request: URLRequest, recordTypedNavigation: Bool) {
        navigateWithoutInsecureHTTPPrompt(request: request, recordTypedNavigation: recordTypedNavigation)
    }

    /// Opens `url` in the system default browser (host primitive).
    func openURLInDefaultBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func presentInsecureHTTPAlert(
        for request: URLRequest,
        intent: BrowserInsecureHTTPNavigationIntent,
        recordTypedNavigation: Bool
    ) {
        guard let url = request.url else { return }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return }

        let alert = insecureHTTPAlertFactory()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "browser.error.insecure.title", defaultValue: "Connection isn\u{2019}t secure")
        alert.informativeText = String(localized: "browser.error.insecure.message", defaultValue: "\(host) uses plain HTTP, so traffic can be read or modified on the network.\n\nOpen this URL in your default browser, or proceed in cmux.")
        alert.addButton(withTitle: String(localized: "browser.openInDefaultBrowser", defaultValue: "Open in Default Browser"))
        alert.addButton(withTitle: String(localized: "browser.proceedInCmux", defaultValue: "Proceed in cmux"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "browser.alwaysAllowHost", defaultValue: "Always allow this host in cmux")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self, weak alert] response in
            self?.navigationIntentCoordinator.resolveAlertResponse(
                response,
                suppressionEnabled: alert?.suppressionButton?.state == .on,
                host: host,
                request: request,
                url: url,
                intent: intent,
                recordTypedNavigation: recordTypedNavigation
            )
        }

        if shouldDeferPromptUntilInteractiveHost(for: webView) {
            presentBrowserAlert(alert, in: webView, completion: handleResponse, cancel: {})
            return
        }

        if let alertWindow = insecureHTTPAlertWindowProvider() {
            alert.beginSheetModal(for: alertWindow, completionHandler: handleResponse)
            return
        }

        handleResponse(alert.runModal())
    }

    deinit {
        hiddenWebViewDiscardManager.stop()
        developerToolsRestoreRetryWorkItem?.cancel()
        developerToolsRestoreRetryWorkItem = nil
        developerToolsTransitionSettleWorkItem?.cancel()
        developerToolsTransitionSettleWorkItem = nil
        developerToolsVisibilityLossCheckWorkItem?.cancel()
        developerToolsVisibilityLossCheckWorkItem = nil
        detachedDeveloperToolsWindowCloseResolutionTimer?.cancel()
        detachedDeveloperToolsWindowCloseResolutionTimer = nil
        detachedDeveloperToolsWindowCloseResolutionGeneration &+= 1
        if let detachedDeveloperToolsWindowCloseObserver {
            NotificationCenter.default.removeObserver(detachedDeveloperToolsWindowCloseObserver)
        }
        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        let webView = webView
        Task { @MainActor in
            BrowserWindowPortalRegistry.detach(webView: webView)
        }
    }
}

extension BrowserPanel: BrowserHiddenWebViewDiscardManagerDelegate {
    var hiddenWebViewDiscardSnapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
        BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
            isClosing: isClosingWebViewLifecycle,
            isVisibleInUI: isWebViewVisibleInUI,
            shouldRenderWebView: shouldRenderWebView,
            hasPendingRemoteNavigation: navigationIntentCoordinator.pendingRemoteNavigation != nil,
            hasCurrentURL: (currentURL ?? BrowserRemoteProxyURLRewriter.displayURL(for: webView.url)) != nil,
            isLoading: isLoading,
            webViewIsLoading: webView.isLoading,
            hasActiveMainFrameProvisionalNavigation: isMainFrameProvisionalNavigationActive,
            isDownloading: isDownloading,
            activeDownloadCount: downloadActivityCoordinator.activeDownloadCount,
            preferredDeveloperToolsVisible: preferredDeveloperToolsVisible,
            isDeveloperToolsVisible: isDeveloperToolsVisible(),
            isElementFullscreenActive: isElementFullscreenActive,
            isReactGrabActive: isReactGrabActive,
            isVisualAutomationCaptureActive: activeVisualAutomationCaptureCount > 0,
            hasPopups: !popupControllers.isEmpty,
            isCapturingMedia: webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none,
            isPlayingMedia: isPlayingMedia
        )
    }

    var hiddenWebViewDiscardHiddenAt: Date? {
        webViewLastHiddenAt
    }

    var hiddenWebViewDiscardWebViewInstanceID: UUID {
        webViewInstanceID
    }

    func hiddenWebViewDiscardManagerDidRequestDiscard(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {
        discardHiddenWebViewForMemory(reason: reason)
    }

    func hiddenWebViewDiscardManagerPolicyDidChange(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {
        reevaluateHiddenWebViewDiscardScheduling(reason: reason)
    }
}

extension BrowserPanel {
    private var needsWorkspaceContextReset: Bool {
        shouldRenderWebView ||
        currentURL != nil ||
        !pageTitle.isEmpty ||
        faviconPNGData != nil ||
        searchState != nil ||
        isBrowserFocusModeActive ||
        isBrowserFocusModeExitArmed ||
        nativeCanGoBack ||
        nativeCanGoForward ||
        restoredSessionHistoryHasState ||
        estimatedProgress > 0 ||
        isLoading ||
        isDownloading ||
        downloadActivityCoordinator.activeDownloadCount != 0 ||
        preferredDeveloperToolsVisible ||
        hasRecoverableWebContentTermination ||
        pendingWebContentRecoveryURL != nil ||
        webView.superview != nil
    }

    func resetForWorkspaceContextChange(reason: String) {
        guard needsWorkspaceContextReset else {
            resetWebViewLifecycleMetadata()
#if DEBUG
            cmuxDebugLog(
                "browser.contextReset.skip panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) render=\(shouldRenderWebView ? 1 : 0)"
            )
#endif
            return
        }

#if DEBUG
        cmuxDebugLog(
            "browser.contextReset.begin panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) render=\(shouldRenderWebView ? 1 : 0) " +
            "url=\(preferredURLStringForOmnibar() ?? "nil")"
        )
#endif

        _ = hideDeveloperTools()
        clearBrowserFocusMode(reason: "contextReset")
        cancelDeveloperToolsRestoreRetry()
        setPreferredDeveloperToolsVisible(false)
        preferredDeveloperToolsPresentation = .unknown
        forceDeveloperToolsRefreshOnNextAttach = false
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsRestoreRetryAttempt = 0
        preferredAttachedDeveloperToolsWidth = nil
        preferredAttachedDeveloperToolsWidthFraction = nil
        clearWebContentTerminationRecovery()

        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil
        faviconCoordinator.cancelInFlightRefreshInvalidatingGeneration()
        loadingGeneration &+= 1
        downloadActivityCoordinator.resetCount()
        isDownloading = false
        isLoading = false
        estimatedProgress = 0
        nativeCanGoBack = false
        nativeCanGoForward = false
        navigationDelegate?.lastAttemptedURL = nil
        abandonRestoredSessionHistoryIfNeeded()

        pendingAddressBarFocusRequestId = nil
        pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
        preferredFocusIntent = .addressBar
        suppressOmnibarAutofocusUntil = nil
        suppressWebViewFocusUntil = nil
        endSuppressWebViewFocusForAddressBar()
        invalidateAddressBarPageFocusRestoreAttempts()
        invalidateSearchFocusRequests(reason: "contextReset")
        searchState = nil

        pageTitle = ""
        currentURL = nil
        hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
        faviconPNGData = nil
        faviconCoordinator.clearLastFaviconURLString()
        resetWebViewLifecycleMetadata()
        activePortalHostLease = nil
        pendingDistinctPortalHostReplacementPaneId = nil
        lockedPortalHost = nil

        let oldWebView = webView
        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        cancelPendingInteractiveBrowserPrompts(reason: "contextReset")
        closeBackgroundPreloadHost(reason: "contextReset")
        BrowserWindowPortalRegistry.detach(webView: oldWebView)
        webAuthnCoordinator.uninstall(from: oldWebView)
        oldWebView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
        oldWebView.navigationDelegate = nil
        oldWebView.uiDelegate = nil
        if let oldCmuxWebView = oldWebView as? CmuxWebView {
            oldCmuxWebView.onContextMenuDownloadStateChanged = nil
        }

        let replacement = Self.makeWebView(
            profileID: profileID,
            websiteDataStore: websiteDataStore
        )
        webViewInstanceID = UUID()
        webView = replacement
        shouldRenderWebView = false
        refreshWebViewLifecycleState()
        bindWebView(replacement)
        applyBrowserThemeModeIfNeeded()
        refreshNavigationAvailability()

#if DEBUG
        cmuxDebugLog(
            "browser.contextReset.end panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) instance=\(webViewInstanceID.uuidString.prefix(6))"
        )
#endif
    }
}

extension BrowserPanel {
    private func cancelInFlightNavigationBeforeHistoryTraversal() {
        guard webView.isLoading || isMainFrameProvisionalNavigationActive else { return }
        webView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        let applied = applyMuteState(muted, to: webView, reason: "setMuted")
        if applied, isMuted != muted {
            isMuted = muted
        }
        return applied
    }

    @discardableResult
    func toggleMute() -> Bool {
        setMuted(!isMuted)
    }

    /// Go back in history
    func goBack() {
        guard canGoBack else { return }
        reactivateDiscardedWebViewWithoutNavigation(reason: "goBack")
        cancelInFlightNavigationBeforeHistoryTraversal()
        if sessionHistoryCoordinator.goBack() {
            return
        }

        webView.goBack()
    }

    /// Go forward in history
    func goForward() {
        guard canGoForward else { return }
        reactivateDiscardedWebViewWithoutNavigation(reason: "goForward")
        cancelInFlightNavigationBeforeHistoryTraversal()
        if sessionHistoryCoordinator.goForward() {
            return
        }

        webView.goForward()
    }

    /// Open a link in a new browser surface in the same pane
    func openLinkInNewTab(url: URL, bypassInsecureHTTPHostOnce: String? = nil) {
        openLinkInNewTab(
            request: URLRequest(url: url),
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        )
    }

    /// Opens a request in a sibling browser tab without dropping request metadata.
    func openLinkInNewTab(request: URLRequest, bypassInsecureHTTPHostOnce: String? = nil) {
        guard let seed = BrowserNewTabNavigationSeed.make(
            from: request,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        ) else {
            return
        }
#if DEBUG
        cmuxDebugLog(
            "browser.newTab.open.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) url=\(browserNavigationDebugURL(seed.url)) " +
            "bypass=\(seed.bypassInsecureHTTPHostOnce ?? "nil")"
        )
#endif
        guard BrowserAvailabilitySettings.isEnabled() else {
            _ = NSWorkspace.shared.open(seed.url)
#if DEBUG
            cmuxDebugLog("browser.newTab.open.external panel=\(id.uuidString.prefix(5)) reason=browser_disabled")
#endif
            return
        }
        guard let app = AppDelegate.shared else {
#if DEBUG
            cmuxDebugLog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=missingAppDelegate")
#endif
            return
        }
        guard let workspace = app.workspaceContainingPanel(
            panelId: id,
            preferredWorkspaceId: workspaceId
        )?.workspace else {
#if DEBUG
            cmuxDebugLog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=workspaceMissing")
#endif
            return
        }
        guard let paneId = workspace.paneId(forPanelId: id) else {
#if DEBUG
            cmuxDebugLog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=paneMissing")
#endif
            return
        }
        guard let _ = workspace.newBrowserSurface(
            inPane: paneId,
            url: seed.url,
            initialRequest: seed.initialRequest,
            focus: true,
            preferredProfileID: profileID,
            bypassInsecureHTTPHostOnce: seed.bypassInsecureHTTPHostOnce
        ) else {
#if DEBUG
            cmuxDebugLog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=newPanelFailed")
#endif
            return
        }
#if DEBUG
        cmuxDebugLog(
            "browser.newTab.open.done panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) pane=\(paneId.id.uuidString.prefix(5))"
        )
#endif
    }

    var currentURLForTabDuplication: URL? {
        resolvedCurrentSessionHistoryURL()
            ?? BrowserRemoteProxyURLRewriter.displayURL(for: webView.url)
            ?? currentURL
    }

    var bypassesRemoteWorkspaceProxyForTabDuplication: Bool {
        bypassesRemoteWorkspaceProxy
    }

    private func prepareForReload(reason: String, mode: BrowserPanelReloadMode) -> Bool {
        if recoverTerminatedWebContent(reason: reason, cachePolicy: mode.recoveryCachePolicy) {
            return true
        }
        if restoreDiscardedWebViewIfNeeded(reason: reason, cachePolicy: mode.recoveryCachePolicy) {
            return true
        }
        webView.customUserAgent = String.safariDesktopUserAgent
        if Self.serializableSessionHistoryURLString(BrowserRemoteProxyURLRewriter.displayURL(for: webView.url)) == nil {
            let fallbackURL = resolvedCurrentSessionHistoryURL()
                ?? BrowserRemoteProxyURLRewriter.displayURL(for: navigationDelegate?.lastAttemptedURL)

            if let fallbackURL,
               Self.serializableSessionHistoryURLString(fallbackURL) != nil {
                navigateWithoutInsecureHTTPPrompt(
                    to: fallbackURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: usesRestoredSessionHistory,
                    cachePolicy: mode.recoveryCachePolicy
                )
                return true
            }
        }
        return false
    }

    /// Reload the current page
    func reload() {
        if prepareForReload(reason: "reload", mode: .soft) {
            return
        }
        webView.reload()
    }

    /// Reload the current page, bypassing WebKit's cache.
    func hardReload() {
        if prepareForReload(reason: "hardReload", mode: .hard) {
            return
        }
        webView.reloadFromOrigin()
    }

    /// Stop loading
    func stopLoading() {
        webView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
    }

    private static func windowContainsInspectorViews(_ root: NSView) -> Bool {
        if root.isCmuxWebInspectorObject {
            return true
        }
        for subview in root.subviews where windowContainsInspectorViews(subview) {
            return true
        }
        return false
    }

    static func isDetachedInspectorWindow(_ window: NSWindow) -> Bool {
        guard window.title.hasPrefix("Web Inspector") else { return false }
        guard let contentView = window.contentView else { return false }
        return windowContainsInspectorViews(contentView)
    }

    private func detachedDeveloperToolsWindows() -> [NSWindow] {
        let mainWindow = webView.window
        return NSApp.windows.filter { candidate in
            if let mainWindow, candidate === mainWindow {
                return false
            }
            return Self.isDetachedInspectorWindow(candidate)
        }
    }

    private func detachedDeveloperToolsWindowsForPanel() -> [NSWindow] {
        detachedDeveloperToolsWindows().filter(detachedDeveloperToolsWindowBelongsToPanel)
    }

    private var hasPendingDetachedDeveloperToolsWindowCloseResolution: Bool {
        detachedDeveloperToolsWindowCloseResolutionTimer != nil
    }

    private func hasAttachedDeveloperToolsLayout() -> Bool {
        guard let container = webView.superview else { return false }
        return Self.visibleDescendants(in: container)
            .contains { Self.isVisibleSideDockInspectorCandidate($0) && Self.isInspectorView($0) }
    }

    private func setPreferredDeveloperToolsPresentation(_ next: DeveloperToolsPresentation) {
        guard preferredDeveloperToolsPresentation != next else { return }
        preferredDeveloperToolsPresentation = next
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func setPreferredDeveloperToolsVisible(_ next: Bool) {
        guard preferredDeveloperToolsVisible != next else { return }
        preferredDeveloperToolsVisible = next
    }

    private func reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden() {
        guard !preferredDeveloperToolsVisible, !isDeveloperToolsVisible() else { return }
        reevaluateHiddenWebViewDiscardScheduling(reason: "developer_tools_visibility_changed")
    }

    private func syncDeveloperToolsPresentationPreferenceFromUI() {
        if hasAttachedDeveloperToolsLayout() {
            setPreferredDeveloperToolsPresentation(.attached)
            developerToolsDetachedOpenGraceDeadline = nil
        } else if !detachedDeveloperToolsWindows().isEmpty {
            setPreferredDeveloperToolsPresentation(.detached)
        }
    }

    private func installDetachedDeveloperToolsWindowCloseObserver() {
        guard detachedDeveloperToolsWindowCloseObserver == nil else { return }
        detachedDeveloperToolsWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow else { return }
            guard Thread.isMainThread else { return }
            let handledDetachedInspector = MainActor.assumeIsolated {
                guard Self.isDetachedInspectorWindow(window) else { return false }
                return self.handleDetachedDeveloperToolsWindowWillClose(window)
            }
            _ = handledDetachedInspector
        }
    }

    @discardableResult
    private func handleDetachedDeveloperToolsWindowWillClose(_ window: NSWindow) -> Bool {
        guard detachedDeveloperToolsWindowBelongsToPanel(window) else { return false }
        // Explicit user closes are intercepted in AppDelegate before AppKit posts
        // willClose. A raw willClose can also be WebKit's redock path, where
        // closing _inspector here tears down the frontend while attach continues.
        scheduleDetachedDeveloperToolsWindowCloseResolution(source: "willClose")
#if DEBUG
        cmuxDebugLog(
            "browser.devtools detachedClose.defer panel=\(id.uuidString.prefix(5)) " +
            "window=\(window.windowNumber) \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        return true
    }

    @discardableResult
    func closeDeveloperToolsFromDetachedInspectorWindowUserAction(
        _ window: NSWindow,
        source: String
    ) -> Bool {
        closeDeveloperToolsFromDetachedInspectorWindow(window, source: source)
    }

    @discardableResult
    private func closeDeveloperToolsFromDetachedInspectorWindow(
        _ window: NSWindow,
        source: String
    ) -> Bool {
        guard detachedDeveloperToolsWindowBelongsToPanel(window) else { return false }
        let closed = closeDeveloperToolsForTeardown()
#if DEBUG
        cmuxDebugLog(
            "browser.devtools detachedClose.\(source) panel=\(id.uuidString.prefix(5)) " +
            "closed=\(closed ? 1 : 0) \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        return closed
    }

    private func scheduleDetachedDeveloperToolsWindowCloseResolution(
        source: String,
        startedAt: Date = Date()
    ) {
        detachedDeveloperToolsWindowCloseResolutionTimer?.cancel()
        detachedDeveloperToolsWindowCloseResolutionGeneration &+= 1
        let generation = detachedDeveloperToolsWindowCloseResolutionGeneration
        let delayNanoseconds = Int(developerToolsAttachedManualCloseDetectionDelay * 1_000_000_000)
        // WebKit exposes no completion callback for re-dock. It closes the
        // detached window before the attached frontend/layout is observable.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .nanoseconds(delayNanoseconds))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.detachedDeveloperToolsWindowCloseResolutionTimer != nil else { return }
            guard self.detachedDeveloperToolsWindowCloseResolutionGeneration == generation else { return }
            self.detachedDeveloperToolsWindowCloseResolutionTimer?.cancel()
            self.detachedDeveloperToolsWindowCloseResolutionTimer = nil
            self.resolveDetachedDeveloperToolsWindowClose(source: source, startedAt: startedAt)
        }
        detachedDeveloperToolsWindowCloseResolutionTimer = timer
        timer.resume()
    }

    private func resolveDetachedDeveloperToolsWindowClose(source: String, startedAt: Date) {
        guard detachedDeveloperToolsWindowsForPanel().isEmpty else { return }
        guard preferredDeveloperToolsVisible || isDeveloperToolsVisible() else { return }

        let visible = isDeveloperToolsVisible()
        let hasAttachedLayout = hasAttachedDeveloperToolsLayout()
        if visible || hasAttachedLayout {
            developerToolsDetachedOpenGraceDeadline = nil
            setPreferredDeveloperToolsVisible(true)
            if hasAttachedLayout {
                setPreferredDeveloperToolsPresentation(.attached)
            } else {
                syncDeveloperToolsPresentationPreferenceFromUI()
                if detachedDeveloperToolsWindowsForPanel().isEmpty {
                    setPreferredDeveloperToolsPresentation(.attached)
                }
            }
            developerToolsLastKnownVisibleAt = Date()
            cancelDeveloperToolsRestoreRetry()
#if DEBUG
            cmuxDebugLog(
                "browser.devtools detachedClose.redock panel=\(id.uuidString.prefix(5)) " +
                "source=\(source) \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
            )
#endif
            return
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        // WebKit's attach path is not reflected in cmux's transition flag, so a
        // no-window/no-layout state remains ambiguous until the bounded deadline.
        if preferredDeveloperToolsVisible,
           elapsed < developerToolsDetachedWindowCloseResolutionMaxDuration {
            scheduleDetachedDeveloperToolsWindowCloseResolution(
                source: "\(source).ambiguous",
                startedAt: startedAt
            )
            return
        }

        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsLastKnownVisibleAt = nil
        forceDeveloperToolsRefreshOnNextAttach = false
        setPreferredDeveloperToolsVisible(false)
        reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
        cancelDeveloperToolsRestoreRetry()
#if DEBUG
        cmuxDebugLog(
            "browser.devtools detachedClose.manual panel=\(id.uuidString.prefix(5)) " +
            "source=\(source) \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
    }

    private func detachedDeveloperToolsWindowBelongsToPanel(_ window: NSWindow) -> Bool {
        guard let frontendWebView = webView.cmuxInspectorFrontendWebView(),
              let contentView = window.contentView else {
            return false
        }
        return frontendWebView === contentView || frontendWebView.isDescendant(of: contentView)
    }

    private func shouldDismissDetachedDeveloperToolsWindows() -> Bool {
        preferredDeveloperToolsPresentation == .attached
    }

    private func dismissDetachedDeveloperToolsWindowsIfNeeded() {
        guard shouldDismissDetachedDeveloperToolsWindows() else { return }
        guard preferredDeveloperToolsVisible || isDeveloperToolsVisible(),
              let mainWindow = webView.window else { return }
        for window in NSApp.windows where window !== mainWindow && Self.isDetachedInspectorWindow(window) {
#if DEBUG
            cmuxDebugLog(
                "browser.devtools strayWindow.close panel=\(id.uuidString.prefix(5)) " +
                "title=\(window.title) frame=\(NSStringFromRect(window.frame))"
            )
#endif
            window.close()
        }
    }

    private func scheduleDetachedDeveloperToolsWindowDismissal() {
        guard shouldDismissDetachedDeveloperToolsWindows() else { return }
        for delay in [0.0, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.dismissDetachedDeveloperToolsWindowsIfNeeded()
            }
        }
    }

    private func prepareDeveloperToolsForRevealIfNeeded(_ inspector: NSObject) {
        if preferredDeveloperToolsPresentation != .unknown {
            guard preferredDeveloperToolsPresentation == .attached else { return }
            guard webView.superview != nil, webView.window != nil else { return }
            guard inspector.cmuxCallBool(selector: NSSelectorFromString("isAttached")) == false else { return }
        }
        let attachSelector = NSSelectorFromString("attach")
        guard inspector.responds(to: attachSelector) else { return }
        inspector.cmuxCallVoid(selector: attachSelector)
    }

    @discardableResult
    private func revealDeveloperTools(_ inspector: NSObject) -> Bool {
        let isVisibleSelector = NSSelectorFromString("isVisible")
        if inspector.cmuxCallBool(selector: isVisibleSelector) ?? false {
            developerToolsDetachedOpenGraceDeadline = nil
            developerToolsLastKnownVisibleAt = Date()
            return true
        }

        prepareDeveloperToolsForRevealIfNeeded(inspector)

        let showSelector = NSSelectorFromString("show")
        guard inspector.responds(to: showSelector) else { return false }
        inspector.cmuxCallVoid(selector: showSelector)
        let visibleAfterShow = inspector.cmuxCallBool(selector: isVisibleSelector) ?? false
        if visibleAfterShow {
            developerToolsLastKnownVisibleAt = Date()
        }
        if preferredDeveloperToolsPresentation == .detached {
            developerToolsDetachedOpenGraceDeadline = visibleAfterShow
                ? nil
                : Date().addingTimeInterval(developerToolsDetachedOpenGracePeriod)
        } else {
            developerToolsDetachedOpenGraceDeadline = nil
        }
        return visibleAfterShow
    }

    @discardableResult
    private func concealDeveloperTools(_ inspector: NSObject) -> Bool {
        let isVisibleSelector = NSSelectorFromString("isVisible")
        guard inspector.cmuxCallBool(selector: isVisibleSelector) ?? false else { return true }

        var invokedSelector = false
        for rawSelector in ["hide", "close"] {
            let selector = NSSelectorFromString(rawSelector)
            guard inspector.responds(to: selector) else { continue }
            invokedSelector = true
            inspector.cmuxCallVoid(selector: selector)
            if !(inspector.cmuxCallBool(selector: isVisibleSelector) ?? false) {
                return true
            }
        }

        guard invokedSelector else { return false }
        return !(inspector.cmuxCallBool(selector: isVisibleSelector) ?? false)
    }

    private var isDeveloperToolsTransitionInFlight: Bool {
        developerToolsTransitionSettleWorkItem != nil
    }

    private func effectiveDeveloperToolsVisibilityIntent() -> Bool {
        if let pendingDeveloperToolsTransitionTargetVisible {
            return pendingDeveloperToolsTransitionTargetVisible
        }
        if let developerToolsTransitionTargetVisible {
            return developerToolsTransitionTargetVisible
        }
        return isDeveloperToolsVisible()
    }

    private func scheduleDeveloperToolsTransitionSettle(source: String) {
        developerToolsTransitionSettleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.developerToolsTransitionSettleWorkItem = nil
            self?.finishDeveloperToolsTransition(source: source)
        }
        developerToolsTransitionSettleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + developerToolsTransitionSettleDelay, execute: workItem)
    }

    private func finishDeveloperToolsTransition(source: String) {
        let pendingTargetVisible = pendingDeveloperToolsTransitionTargetVisible
        pendingDeveloperToolsTransitionTargetVisible = nil
        developerToolsTransitionTargetVisible = nil

        guard let pendingTargetVisible else { return }
        guard pendingTargetVisible != isDeveloperToolsVisible() else { return }
        _ = performDeveloperToolsVisibilityTransition(to: pendingTargetVisible, source: "\(source).queued")
    }

    @discardableResult
    private func enqueueDeveloperToolsVisibilityTransition(
        to targetVisible: Bool,
        source: String
    ) -> Bool {
        if isDeveloperToolsTransitionInFlight {
            pendingDeveloperToolsTransitionTargetVisible = targetVisible
            setPreferredDeveloperToolsVisible(targetVisible)
            if !targetVisible {
                developerToolsDetachedOpenGraceDeadline = nil
                forceDeveloperToolsRefreshOnNextAttach = false
                cancelDeveloperToolsRestoreRetry()
            }
#if DEBUG
            cmuxDebugLog(
                "browser.devtools transition.queue panel=\(id.uuidString.prefix(5)) " +
                "source=\(source) target=\(targetVisible ? 1 : 0) \(debugDeveloperToolsStateSummary())"
            )
#endif
            return true
        }

        return performDeveloperToolsVisibilityTransition(to: targetVisible, source: source)
    }

    @discardableResult
    private func performDeveloperToolsVisibilityTransition(
        to targetVisible: Bool,
        source: String
    ) -> Bool {
        guard let inspector = webView.cmuxInspectorObject() else { return false }

        let isVisibleSelector = NSSelectorFromString("isVisible")
        let visible = inspector.cmuxCallBool(selector: isVisibleSelector) ?? false
        setPreferredDeveloperToolsVisible(targetVisible)
        developerToolsTransitionTargetVisible = targetVisible
        if targetVisible {
            reevaluateHiddenWebViewDiscardScheduling(reason: "developer_tools_visibility_changed")
        }

        if targetVisible {
            if !visible {
                _ = revealDeveloperTools(inspector)
            } else {
                developerToolsDetachedOpenGraceDeadline = nil
            }
        } else {
            if visible {
                syncDeveloperToolsPresentationPreferenceFromUI()
                guard concealDeveloperTools(inspector) else {
                    developerToolsTransitionTargetVisible = nil
                    return false
                }
            }
            developerToolsDetachedOpenGraceDeadline = nil
        }

        if targetVisible {
            let visibleAfterTransition = inspector.cmuxCallBool(selector: isVisibleSelector) ?? false
            if visibleAfterTransition {
                syncDeveloperToolsPresentationPreferenceFromUI()
                cancelDeveloperToolsRestoreRetry()
                scheduleDetachedDeveloperToolsWindowDismissal()
            } else {
                developerToolsRestoreRetryAttempt = 0
                scheduleDeveloperToolsRestoreRetry()
            }
        } else {
            cancelDeveloperToolsRestoreRetry()
            forceDeveloperToolsRefreshOnNextAttach = false
            reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
        }

        if visible != targetVisible {
            scheduleDeveloperToolsTransitionSettle(source: source)
        } else {
            developerToolsTransitionTargetVisible = nil
        }

        return true
    }

    @discardableResult
    func toggleDeveloperTools() -> Bool {
#if DEBUG
        cmuxDebugLog(
            "browser.devtools toggle.begin panel=\(id.uuidString.prefix(5)) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        let targetVisible = !effectiveDeveloperToolsVisibilityIntent()
        let handled = enqueueDeveloperToolsVisibilityTransition(to: targetVisible, source: "toggle")
#if DEBUG
        cmuxDebugLog(
            "browser.devtools toggle.end panel=\(id.uuidString.prefix(5)) targetVisible=\(targetVisible ? 1 : 0) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            cmuxDebugLog(
                "browser.devtools toggle.tick panel=\(self.id.uuidString.prefix(5)) " +
                "\(self.debugDeveloperToolsStateSummary()) \(self.debugDeveloperToolsGeometrySummary())"
            )
        }
#endif
        return handled
    }

    @discardableResult
    func showDeveloperTools() -> Bool {
        return enqueueDeveloperToolsVisibilityTransition(to: true, source: "show")
    }

    @discardableResult
    func showDeveloperToolsConsole() -> Bool {
        guard showDeveloperTools() else { return false }
        guard !isDeveloperToolsTransitionInFlight else { return true }
        guard let inspector = webView.cmuxInspectorObject() else { return true }
        // WebKit private inspector API differs by OS; try known console selectors.
        let consoleSelectors = [
            "showConsole",
            "showConsoleTab",
            "showConsoleView",
        ]
        for raw in consoleSelectors {
            let selector = NSSelectorFromString(raw)
            if inspector.responds(to: selector) {
                inspector.cmuxCallVoid(selector: selector)
                break
            }
        }
        return true
    }

    @discardableResult
    func closeDeveloperToolsForTeardown() -> Bool {
        developerToolsTransitionSettleWorkItem?.cancel()
        developerToolsTransitionSettleWorkItem = nil
        pendingDeveloperToolsTransitionTargetVisible = nil
        developerToolsTransitionTargetVisible = nil
        detachedDeveloperToolsWindowCloseResolutionTimer?.cancel()
        detachedDeveloperToolsWindowCloseResolutionTimer = nil
        detachedDeveloperToolsWindowCloseResolutionGeneration &+= 1
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsLastKnownVisibleAt = nil
        forceDeveloperToolsRefreshOnNextAttach = false
        cancelDeveloperToolsRestoreRetry()

        let closed = WebViewInspectorTeardown.closeInspector(for: webView)
        setPreferredDeveloperToolsVisible(false)
        return closed
    }

    /// Called before WKWebView detaches so manual inspector closes are respected.
    func syncDeveloperToolsPreferenceFromInspector(preserveVisibleIntent: Bool = false) {
        guard let inspector = webView.cmuxInspectorObject() else { return }
        guard let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) else { return }
        if isDeveloperToolsTransitionInFlight {
            let targetVisible = pendingDeveloperToolsTransitionTargetVisible ?? developerToolsTransitionTargetVisible ?? visible
            setPreferredDeveloperToolsVisible(targetVisible)
            if targetVisible, visible {
                developerToolsDetachedOpenGraceDeadline = nil
                syncDeveloperToolsPresentationPreferenceFromUI()
                cancelDeveloperToolsRestoreRetry()
            } else if !targetVisible {
                developerToolsDetachedOpenGraceDeadline = nil
                forceDeveloperToolsRefreshOnNextAttach = false
                cancelDeveloperToolsRestoreRetry()
            }
            return
        }
        if visible {
            developerToolsDetachedOpenGraceDeadline = nil
            syncDeveloperToolsPresentationPreferenceFromUI()
            setPreferredDeveloperToolsVisible(true)
            developerToolsLastKnownVisibleAt = Date()
            cancelDeveloperToolsRestoreRetry()
            return
        }
        if hasPendingDetachedDeveloperToolsWindowCloseResolution {
            return
        }
        if preserveVisibleIntent && preferredDeveloperToolsVisible {
            return
        }
        setPreferredDeveloperToolsVisible(false)
        developerToolsLastKnownVisibleAt = nil
        reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
        cancelDeveloperToolsRestoreRetry()
    }

    func noteDeveloperToolsHostAttached() {
        cancelPendingDeveloperToolsVisibilityLossCheck()
        // `developerToolsLastAttachedHostAt` anchors the manual-close detection
        // grace (see `consumeAttachedDeveloperToolsManualCloseIfNeeded`). Refresh it
        // only when this attach reflects genuine inspector churn: the inspector is
        // currently visible, a forced refresh is pending, or a restore retry is in
        // flight. While DevTools intent is set the browser stays in local-inline
        // hosting, so `BrowserPanelView` re-runs this on every `updateNSView`. A
        // plain re-render (e.g. navigating to another page) is not a reattach;
        // resetting the grace there would defer a user's manual inspector close
        // indefinitely and let `restoreDeveloperToolsAfterAttachIfNeeded` reopen it.
        if developerToolsLastAttachedHostAt == nil || hasActiveDeveloperToolsReattachReason {
            developerToolsLastAttachedHostAt = Date()
        }
        if isDeveloperToolsVisible() {
            developerToolsLastKnownVisibleAt = Date()
        }
    }

    /// Whether a host attach should count as genuine inspector churn that resets
    /// the manual-close grace window, rather than a steady-state re-render while
    /// the inspector is already closed.
    private var hasActiveDeveloperToolsReattachReason: Bool {
        isDeveloperToolsVisible()
            || forceDeveloperToolsRefreshOnNextAttach
            || developerToolsRestoreRetryWorkItem != nil
    }

    func scheduleDeveloperToolsVisibilityLossCheck() {
        developerToolsVisibilityLossCheckWorkItem?.cancel()
        let attachedAge = developerToolsLastAttachedHostAt.map { Date().timeIntervalSince($0) } ?? 0
        let delay = max(
            developerToolsTransitionSettleDelay,
            developerToolsAttachedManualCloseDetectionDelay - attachedAge
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.developerToolsVisibilityLossCheckWorkItem = nil
            _ = self.consumeAttachedDeveloperToolsManualCloseIfNeeded()
        }
        developerToolsVisibilityLossCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: workItem
        )
    }

    func cancelPendingDeveloperToolsVisibilityLossCheck() {
        developerToolsVisibilityLossCheckWorkItem?.cancel()
        developerToolsVisibilityLossCheckWorkItem = nil
    }

    @discardableResult
    func consumeAttachedDeveloperToolsManualCloseIfNeeded(inspector: NSObject? = nil) -> Bool {
        guard preferredDeveloperToolsVisible else { return false }
        guard preferredDeveloperToolsPresentation != .detached else { return false }
        guard !isDeveloperToolsTransitionInFlight else { return false }
        guard webView.superview != nil, webView.window != nil else { return false }
        guard let developerToolsLastAttachedHostAt else { return false }
        guard Date().timeIntervalSince(developerToolsLastAttachedHostAt) >= developerToolsAttachedManualCloseDetectionDelay else {
            return false
        }
        guard developerToolsLastKnownVisibleAt != nil else { return false }
        guard let inspector = inspector ?? webView.cmuxInspectorObject() else { return false }
        guard let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) else { return false }
        guard !visible else {
            developerToolsLastKnownVisibleAt = Date()
            return false
        }

        setPreferredDeveloperToolsVisible(false)
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsLastKnownVisibleAt = nil
        forceDeveloperToolsRefreshOnNextAttach = false
        reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
        cancelDeveloperToolsRestoreRetry()
#if DEBUG
        cmuxDebugLog(
            "browser.devtools attachedClose.consume panel=\(id.uuidString.prefix(5)) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        return true
    }

    /// Called after WKWebView reattaches to keep inspector stable across split/layout churn.
    func restoreDeveloperToolsAfterAttachIfNeeded() {
        guard preferredDeveloperToolsVisible else {
            cancelDeveloperToolsRestoreRetry()
            forceDeveloperToolsRefreshOnNextAttach = false
            return
        }
        guard !isDeveloperToolsTransitionInFlight else { return }
        guard let inspector = webView.cmuxInspectorObject() else {
            scheduleDeveloperToolsRestoreRetry()
            return
        }

        let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
        if visible {
            let shouldForceRefresh = forceDeveloperToolsRefreshOnNextAttach
            forceDeveloperToolsRefreshOnNextAttach = false
            developerToolsDetachedOpenGraceDeadline = nil
            syncDeveloperToolsPresentationPreferenceFromUI()
            developerToolsLastKnownVisibleAt = Date()
            #if DEBUG
            if shouldForceRefresh {
                cmuxDebugLog("browser.devtools refresh.consumeVisible panel=\(id.uuidString.prefix(5)) \(debugDeveloperToolsStateSummary())")
            }
            #endif
            cancelDeveloperToolsRestoreRetry()
            return
        }

        let detachedOpenStillSettling = developerToolsDetachedOpenGraceDeadline.map { $0 > Date() } ?? false
        if hasPendingDetachedDeveloperToolsWindowCloseResolution {
            return
        }
        let shouldForceRefresh = forceDeveloperToolsRefreshOnNextAttach
        forceDeveloperToolsRefreshOnNextAttach = false
        if preferredDeveloperToolsPresentation == .detached && !detachedOpenStillSettling {
            setPreferredDeveloperToolsVisible(false)
            developerToolsDetachedOpenGraceDeadline = nil
            cancelDeveloperToolsRestoreRetry()
#if DEBUG
            cmuxDebugLog(
                "browser.devtools detachedClose.consume panel=\(id.uuidString.prefix(5)) " +
                "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
            )
#endif
            return
        }

        if consumeAttachedDeveloperToolsManualCloseIfNeeded(inspector: inspector) {
            return
        }

        #if DEBUG
        if shouldForceRefresh {
            cmuxDebugLog("browser.devtools refresh.forceShowWhenHidden panel=\(id.uuidString.prefix(5)) \(debugDeveloperToolsStateSummary())")
        }
        #endif
        // WebKit inspector show can trigger transient first-responder churn while
        // panel attachment is still stabilizing. Keep this auto-restore path from
        // mutating first responder so AppKit doesn't walk tearing-down responder chains.
        AppDelegate.shared?.browserFirstResponderBypass.withBypass {
            _ = revealDeveloperTools(inspector)
        }
        setPreferredDeveloperToolsVisible(true)
        let visibleAfterShow = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
        if visibleAfterShow {
            syncDeveloperToolsPresentationPreferenceFromUI()
            developerToolsLastKnownVisibleAt = Date()
            cancelDeveloperToolsRestoreRetry()
            scheduleDetachedDeveloperToolsWindowDismissal()
        } else {
            scheduleDeveloperToolsRestoreRetry()
        }
    }

    @discardableResult
    func isDeveloperToolsVisible() -> Bool {
        guard let inspector = webView.cmuxInspectorObject() else { return false }
        return inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
    }

    @discardableResult
    func hideDeveloperTools() -> Bool {
        return enqueueDeveloperToolsVisibilityTransition(to: false, source: "hide")
    }

    /// During split/layout transitions SwiftUI can briefly mark the browser surface hidden
    /// while its container is off-window. Avoid detaching in that transient phase if
    /// DevTools is intended to remain open, because detach/reattach can blank inspector content.
    func shouldPreserveWebViewAttachmentDuringTransientHide() -> Bool {
        preferredDeveloperToolsVisible && !hasSideDockedDeveloperToolsLayout()
    }

    func requestDeveloperToolsRefreshAfterNextAttach(reason: String) {
        guard preferredDeveloperToolsVisible else { return }
        forceDeveloperToolsRefreshOnNextAttach = true
        #if DEBUG
        cmuxDebugLog("browser.devtools refresh.request panel=\(id.uuidString.prefix(5)) reason=\(reason) \(debugDeveloperToolsStateSummary())")
        #endif
    }

    func hasPendingDeveloperToolsRefreshAfterAttach() -> Bool {
        forceDeveloperToolsRefreshOnNextAttach
    }

    func shouldPreserveDeveloperToolsIntentWhileDetached() -> Bool {
        preferredDeveloperToolsVisible &&
            (
                forceDeveloperToolsRefreshOnNextAttach ||
                developerToolsRestoreRetryWorkItem != nil ||
                hasPendingDetachedDeveloperToolsWindowCloseResolution ||
                webView.superview == nil ||
                webView.window == nil
            )
    }

    func shouldUseLocalInlineDeveloperToolsHosting() -> Bool {
        guard preferredDeveloperToolsVisible || isDeveloperToolsVisible() else { return false }
        if preferredDeveloperToolsPresentation == .detached {
            return false
        }
        return detachedDeveloperToolsWindows().isEmpty
    }

    func recordPreferredAttachedDeveloperToolsWidth(_ width: CGFloat, containerBounds: NSRect) {
        let normalizedWidth = max(0, width)
        preferredAttachedDeveloperToolsWidth = normalizedWidth
        guard containerBounds.width > 0 else {
            preferredAttachedDeveloperToolsWidthFraction = nil
            return
        }
        preferredAttachedDeveloperToolsWidthFraction = normalizedWidth / containerBounds.width
    }

    func preferredAttachedDeveloperToolsWidthState() -> (width: CGFloat?, widthFraction: CGFloat?) {
        (preferredAttachedDeveloperToolsWidth, preferredAttachedDeveloperToolsWidthFraction)
    }

    @discardableResult
    func zoomIn() -> Bool {
        zoomCoordinator.zoomIn()
    }

    @discardableResult
    func zoomOut() -> Bool {
        zoomCoordinator.zoomOut()
    }

    @discardableResult
    func resetZoom() -> Bool {
        zoomCoordinator.resetZoom()
    }

    func currentPageZoomFactor() -> CGFloat {
        zoomCoordinator.currentPageZoomFactor()
    }

    @discardableResult
    func setPageZoomFactor(_ pageZoom: CGFloat) -> Bool {
        zoomCoordinator.setPageZoomFactor(pageZoom)
    }

    /// The live page-zoom factor of this panel's web view, the only live witness
    /// the `BrowserZoomCoordinator` reads and writes through `BrowserZoomHosting`.
    var livePageZoom: CGFloat {
        get { webView.pageZoom }
        set { webView.pageZoom = newValue }
    }

    /// Take a snapshot of the web view
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) {
        captureAutomationVisibleViewportSnapshot { result in
            switch result {
            case .success(let image):
                completion(image)
            case .failure(let error):
                NSLog("BrowserPanel snapshot error: %@", error.localizedDescription)
                completion(nil)
            }
        }
    }

    func captureAutomationVisibleViewportSnapshot() async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            captureAutomationVisibleViewportSnapshot { result in
                continuation.resume(with: result)
            }
        }
    }

    func captureAutomationVisibleViewportSnapshot(
        completion: @escaping (Result<NSImage, Error>) -> Void
    ) {
        guard visualAutomationCaptureGate.begin() else {
            completion(.failure(BrowserScreenshotError.emptySnapshot))
            return
        }

        withVisualAutomationRenderLease(
            reason: "browser.screenshot",
            timeout: 15.0,
            operation: { webView, afterScreenUpdates, finish in
                BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(
                    from: webView,
                    afterScreenUpdates: afterScreenUpdates,
                    completion: finish
                )
            },
            completion: { [visualAutomationCaptureGate] result in
                visualAutomationCaptureGate.end()
                completion(result)
            }
        )
    }

    private func withVisualAutomationRenderLease<T>(
        reason: String,
        timeout: TimeInterval,
        operation: @escaping (
            _ webView: WKWebView,
            _ afterScreenUpdates: Bool,
            _ finish: @escaping (Result<T, Error>) -> Void
        ) -> Void,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        activeVisualAutomationCaptureCount += 1
        cancelHiddenWebViewDiscard()

        let expectedURLForRestoredWebView = restoredHistoryCurrentURL ?? currentURL
        let restoredDiscardedWebView = restoreDiscardedWebViewIfNeeded(reason: "\(reason).restore")
        let viewportSize = visualAutomationViewportSize()
        let captureWebView = webView
        var timeoutTimer: Timer?
        var didFinish = false
        let usesOffscreenRenderHost = shouldUseOffscreenRenderHostForVisualAutomation

        let finish: (Result<T, Error>) -> Void = { result in
            guard !didFinish else { return }
            didFinish = true
            timeoutTimer?.invalidate()
            timeoutTimer = nil

            self.activeVisualAutomationCaptureCount = max(0, self.activeVisualAutomationCaptureCount - 1)
            self.refreshWebViewLifecycleState()
            if self.activeVisualAutomationCaptureCount == 0, !self.isWebViewVisibleInUI {
                self.scheduleHiddenWebViewDiscardIfNeeded(reason: "\(reason).finished")
            }

            completion(result)
        }

        if usesOffscreenRenderHost {
            ensureVisualAutomationRestoreHostIfNeeded(reason: "\(reason).restoreHost")
            BrowserScreenshotWebViewSnapshotter.withOffscreenRenderHost(
                captureWebView,
                viewportSize: viewportSize,
                expectedURL: restoredDiscardedWebView ? expectedURLForRestoredWebView : nil,
                timeout: timeout,
                operation: { operationFinish in
                    operation(captureWebView, false, operationFinish)
                },
                completion: finish
            )
            return
        }

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            finish(.failure(BrowserScreenshotError.emptySnapshot))
        }

        BrowserScreenshotWebViewSnapshotter.prepareForVisualCapture(
            captureWebView,
            expectedURL: restoredDiscardedWebView ? expectedURLForRestoredWebView : nil
        ) { result in
            switch result {
            case .success:
                operation(captureWebView, false, finish)
            case .failure(let error):
                finish(.failure(error))
            }
        }
    }

    @discardableResult
    func ensureVisualAutomationRestoreHostIfNeeded(reason: String) -> Bool {
        guard shouldUseOffscreenRenderHostForVisualAutomation else { return false }
        guard webView.superview == nil else { return false }
        return ensureBackgroundPreloadHostIfNeeded(reason: reason)
    }

    private var shouldUseOffscreenRenderHostForVisualAutomation: Bool {
        guard isWebViewVisibleInUI else { return true }
        guard webView.window != nil else { return true }
        guard !webView.isHiddenOrHasHiddenAncestor else { return true }
        guard webView.bounds.width > 1, webView.bounds.height > 1 else { return true }
        return false
    }

    private func visualAutomationViewportSize() -> NSSize {
        let candidates = [
            webView.bounds.size,
            webView.frame.size,
            webView.window?.contentView?.bounds.size ?? .zero,
        ]
        for candidate in candidates where candidate.width > 1 && candidate.height > 1 {
            return NSSize(
                width: min(max(candidate.width, 1), 4096),
                height: min(max(candidate.height, 1), 4096)
            )
        }
        return NSSize(width: 1280, height: 720)
    }

    /// Execute JavaScript
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    // MARK: - Find in Page

    func startFind() {
        findCoordinator.startFind()
    }

    func postBrowserSearchFocusNotification(reason: String, generation: UInt64, selectAll: Bool) {
        guard findCoordinator.canApplySearchFocusRequest(generation) else {
#if DEBUG
            cmuxDebugLog(
                "browser.find.focusNotification.skip panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) generation=\(generation)"
            )
#endif
            return
        }
#if DEBUG
        let window = webView.window
        cmuxDebugLog(
            "browser.find.focusNotification panel=\(id.uuidString.prefix(5)) " +
            "generation=\(generation) " +
            "reason=\(reason) selectAll=\(selectAll ? 1 : 0) window=\(window?.windowNumber ?? -1) " +
            "firstResponder=\(String(describing: window?.firstResponder))"
        )
#endif
        NotificationCenter.default.post(name: .browserSearchFocus, object: id, userInfo: [FindFocusNotificationKey.selectAll: selectAll])
    }

    func findNext() {
        findCoordinator.findNext()
    }

    func findPrevious() {
        findCoordinator.findPrevious()
    }

    func hideFind() {
        findCoordinator.hideFind()
    }

    // MARK: - BrowserFindHosting

    /// Whether the find bar is shown, the live witness for
    /// `BrowserFindCoordinator`'s focus-lease and hide decisions.
    var hasFindSearchState: Bool {
        searchState != nil
    }

    /// Whether the panel's semantic focus target is the find field.
    var prefersFindFieldFocus: Bool {
        preferredFocusIntent == .findField
    }

    /// The current find needle, or `nil` when the find bar is hidden.
    var findSearchNeedle: String? {
        searchState?.needle
    }

    /// The 5-character panel-id prefix used in find debug log lines.
    var findDebugPanelIDPrefix: String {
        String(id.uuidString.prefix(5))
    }

    /// Writes the match total into the `@Published` find bar state.
    func setFindMatchTotal(_ value: UInt?) {
        searchState?.total = value
    }

    /// Writes the selected-match index into the `@Published` find bar state.
    func setFindMatchSelected(_ value: UInt?) {
        searchState?.selected = value
    }

    /// Points the panel's semantic focus target at the find field.
    func setPreferredFocusToFindField() {
        preferredFocusIntent = .findField
    }

    /// Ensures the find bar state exists for a `startFind`, recovering the last
    /// needle when it had to be created, and reports whether the find field should
    /// select its existing text on focus.
    func prepareFindSearchStateForStart() -> Bool {
        let created = searchState == nil
        let recoveredNeedle = created ? lastSearchNeedle : ""
        if created { searchState = BrowserSearchState(needle: recoveredNeedle) }
        return created && !recoveredNeedle.isEmpty
    }

    /// Clears any pending address-bar focus request and posts the address-bar-blur
    /// notification, matching `startFind`'s pre-focus cleanup.
    func clearPendingAddressBarFocusForFind() {
        pendingAddressBarFocusRequestId = nil
        pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: id)
    }

    /// Hides the find bar, triggering the panel's `searchState` teardown.
    func clearFindSearchState() {
        searchState = nil
    }

    var canEnterBrowserFocusMode: Bool {
        shouldRenderWebView &&
            browserInteractiveModalHostWindow(for: webView) != nil &&
            !webView.isHiddenOrHasHiddenAncestor &&
            searchState == nil
    }

    var canToggleBrowserFocusMode: Bool {
        isBrowserFocusModeActive || canEnterBrowserFocusMode
    }

    @discardableResult
    func toggleBrowserFocusMode(reason: String, focusWebView: Bool = true) -> Bool {
        setBrowserFocusModeActive(
            !isBrowserFocusModeActive,
            reason: reason,
            focusWebView: focusWebView
        )
    }

    @discardableResult
    func setBrowserFocusModeActive(
        _ active: Bool,
        reason: String,
        focusWebView: Bool = true
    ) -> Bool {
        if !active {
            clearBrowserFocusMode(reason: reason)
            return true
        }

        guard canEnterBrowserFocusMode else {
#if DEBUG
            cmuxDebugLog(
                "browser.focusMode.activate.reject panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) render=\(shouldRenderWebView ? 1 : 0) " +
                "window=\(webView.window == nil ? 0 : 1) hidden=\(webView.isHiddenOrHasHiddenAncestor ? 1 : 0) " +
                "find=\(searchState == nil ? 0 : 1)"
            )
#endif
            return false
        }

        pendingAddressBarFocusRequestId = nil
        pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
        isBrowserFocusModeActive = true
        clearBrowserFocusModeEscapeArms(reason: "\(reason).activate")
        preferredFocusIntent = .webView
        invalidateSearchFocusRequests(reason: "browserFocusModeActivate")

        let didFocus = focusWebView ? requestExplicitWebViewFocus() : true
        guard didFocus else {
            clearBrowserFocusMode(reason: "\(reason).focusFailed")
            return false
        }

#if DEBUG
        cmuxDebugLog("browser.focusMode.activate panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
        NotificationCenter.default.post(name: .browserFocusModeStateDidChange, object: id)
        return true
    }

    func clearBrowserFocusMode(reason: String) {
        let shouldNotify = isBrowserFocusModeActive || isBrowserFocusModeExitArmed
        guard isBrowserFocusModeActive ||
            isBrowserFocusModeExitArmed ||
            browserFocusModeExitArmedAt != nil ||
            lastBrowserFocusModePlainEscapeEventFingerprint != nil
        else { return }
        browserFocusModeExitArmedAt = nil
        lastBrowserFocusModePlainEscapeEventFingerprint = nil
        isBrowserFocusModeExitArmed = false
        isBrowserFocusModeActive = false
#if DEBUG
        cmuxDebugLog("browser.focusMode.clear panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
        if shouldNotify {
            NotificationCenter.default.post(name: .browserFocusModeStateDidChange, object: id)
        }
    }

    func clearBrowserFocusModeEscapeArms(reason: String) {
        clearBrowserFocusModeExitArm(reason: reason)
        lastBrowserFocusModePlainEscapeEventFingerprint = nil
    }

    func clearBrowserFocusModeExitArm(reason: String) {
        guard isBrowserFocusModeExitArmed || browserFocusModeExitArmedAt != nil else { return }
        browserFocusModeExitArmedAt = nil
        isBrowserFocusModeExitArmed = false
#if DEBUG
        cmuxDebugLog("browser.focusMode.escape.disarm panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
    }

    private func browserFocusModeEscapeArmIsFresh(for event: NSEvent) -> Bool {
        guard let startedAt = browserFocusModeExitArmedAt else { return false }
        guard startedAt > 0, event.timestamp > 0 else { return true }
        return max(0, event.timestamp - startedAt) <= Self.browserFocusModeEscapeSequenceInterval
    }

    func handleBrowserFocusModeKeyEvent(_ event: NSEvent, reason: String) -> BrowserFocusModeKeyDecision {
        guard canEnterBrowserFocusMode else {
            clearBrowserFocusMode(reason: "\(reason).ineligible")
            return .inactive
        }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let isPlainEscape = flags.isEmpty && event.keyCode == 53
        guard isPlainEscape else {
            lastBrowserFocusModePlainEscapeEventFingerprint = nil
            clearBrowserFocusModeEscapeArms(reason: "\(reason).nonEscape")
            return isBrowserFocusModeActive ? .forwardToWebView : .inactive
        }

        guard isBrowserFocusModeActive else {
            lastBrowserFocusModePlainEscapeEventFingerprint = nil
            clearBrowserFocusModeEscapeArms(reason: "\(reason).inactiveEscape")
            return .inactive
        }

        guard !event.isARepeat else {
#if DEBUG
            cmuxDebugLog("browser.focusMode.escape.repeat panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
            return .consume
        }

        let eventFingerprint = BrowserFocusModePlainEscapeEventFingerprint(event)
        if lastBrowserFocusModePlainEscapeEventFingerprint == eventFingerprint {
#if DEBUG
            cmuxDebugLog("browser.focusMode.escape.duplicate panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
            return .consume
        }
        lastBrowserFocusModePlainEscapeEventFingerprint = eventFingerprint

        if isBrowserFocusModeExitArmed {
            if browserFocusModeEscapeArmIsFresh(for: event) {
                clearBrowserFocusMode(reason: "\(reason).escapeExit")
                return .consume
            }

            browserFocusModeExitArmedAt = event.timestamp
#if DEBUG
            cmuxDebugLog("browser.focusMode.escape.rearm panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
            return .forwardToWebView
        }

        isBrowserFocusModeExitArmed = true
        browserFocusModeExitArmedAt = event.timestamp
#if DEBUG
        cmuxDebugLog("browser.focusMode.escape.arm panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
        return .forwardToWebView
    }

    private func restoreFindStateAfterNavigation(replaySearch: Bool) {
        findCoordinator.restoreFindStateAfterNavigation(replaySearch: replaySearch)
    }

    func setBrowserThemeMode(_ mode: BrowserThemeMode) {
        browserThemeMode = mode
        applyBrowserThemeModeIfNeeded()
        for controller in popupControllers {
            controller.setBrowserThemeMode(mode)
        }
    }

    func refreshAppearanceDrivenColors() {
        applyConfiguredWebViewBackground()
    }

    func suppressOmnibarAutofocus(for seconds: TimeInterval) {
        suppressOmnibarAutofocusUntil = Date().addingTimeInterval(seconds)
#if DEBUG
        cmuxDebugLog(
            "browser.focus.omnibarAutofocus.suppress panel=\(id.uuidString.prefix(5)) " +
            "seconds=\(String(format: "%.2f", seconds))"
        )
#endif
    }

    func suppressWebViewFocus(for seconds: TimeInterval) {
        suppressWebViewFocusUntil = Date().addingTimeInterval(seconds)
#if DEBUG
        cmuxDebugLog(
            "browser.focus.webView.suppress panel=\(id.uuidString.prefix(5)) " +
            "seconds=\(String(format: "%.2f", seconds))"
        )
#endif
    }

    func clearWebViewFocusSuppression() {
        suppressWebViewFocusUntil = nil
#if DEBUG
        cmuxDebugLog("browser.focus.webView.suppress.clear panel=\(id.uuidString.prefix(5))")
#endif
    }

    func shouldSuppressOmnibarAutofocus() -> Bool {
        if let until = suppressOmnibarAutofocusUntil {
            return Date() < until
        }
        return false
    }

    func shouldSuppressWebViewFocus() -> Bool {
        if suppressWebViewFocusForAddressBar {
            return true
        }
        if searchState != nil {
            return true
        }
        if let until = suppressWebViewFocusUntil {
            return Date() < until
        }
        return false
    }

    func beginSuppressWebViewFocusForAddressBar() {
        let enteringAddressBar = !suppressWebViewFocusForAddressBar
        if enteringAddressBar {
#if DEBUG
            cmuxDebugLog("browser.focus.addressBarSuppress.begin panel=\(id.uuidString.prefix(5))")
#endif
            invalidateAddressBarPageFocusRestoreAttempts()
        }
        suppressWebViewFocusForAddressBar = true
        if enteringAddressBar {
            captureAddressBarPageFocusIfNeeded()
        }
    }

    func endSuppressWebViewFocusForAddressBar() {
        if suppressWebViewFocusForAddressBar {
#if DEBUG
            cmuxDebugLog("browser.focus.addressBarSuppress.end panel=\(id.uuidString.prefix(5))")
#endif
        }
        suppressWebViewFocusForAddressBar = false
    }

    @discardableResult
    func requestAddressBarFocus(
        selectionIntent: BrowserAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
    ) -> UUID {
        clearBrowserFocusMode(reason: "requestAddressBarFocus")
        setOmnibarVisible(true)
        preferredFocusIntent = .addressBar
        invalidateSearchFocusRequests(reason: "requestAddressBarFocus")
        beginSuppressWebViewFocusForAddressBar()
        if let pendingAddressBarFocusRequestId {
            if selectionIntent == .selectAll,
               pendingAddressBarFocusSelectionIntent != .selectAll {
                let requestId = UUID()
                pendingAddressBarFocusSelectionIntent = .selectAll
                self.pendingAddressBarFocusRequestId = requestId
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.addressBar.request panel=\(id.uuidString.prefix(5)) " +
                    "request=\(requestId.uuidString.prefix(8)) result=upgrade_to_select_all"
                )
#endif
                return requestId
            }
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.request panel=\(id.uuidString.prefix(5)) " +
                "request=\(pendingAddressBarFocusRequestId.uuidString.prefix(8)) result=reuse_pending " +
                "selection=\(String(describing: pendingAddressBarFocusSelectionIntent))"
            )
#endif
            return pendingAddressBarFocusRequestId
        }
        let requestId = UUID()
        pendingAddressBarFocusSelectionIntent = selectionIntent
        pendingAddressBarFocusRequestId = requestId
#if DEBUG
        cmuxDebugLog(
            "browser.focus.addressBar.request panel=\(id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) result=new " +
            "selection=\(String(describing: selectionIntent))"
        )
#endif
        return requestId
    }

    @discardableResult
    func setOmnibarVisible(_ visible: Bool) -> Bool {
        guard isOmnibarVisible != visible else { return false }
        isOmnibarVisible = visible
        if !visible {
            pendingAddressBarFocusRequestId = nil
            pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
            if preferredFocusIntent == .addressBar {
                preferredFocusIntent = .webView
            }
            endSuppressWebViewFocusForAddressBar()
            invalidateAddressBarPageFocusRestoreAttempts()
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: id)
        }
        return true
    }

    @discardableResult
    func toggleOmnibarVisibility() -> Bool {
        setOmnibarVisible(!isOmnibarVisible)
        return isOmnibarVisible
    }

    func noteWebViewFocused() {
        guard searchState == nil else { return }
        guard preferredFocusIntent != .webView else { return }
        preferredFocusIntent = .webView
        invalidateSearchFocusRequests(reason: "webViewFocused")
    }

    func noteAddressBarFocused() {
        clearBrowserFocusMode(reason: "addressBarFocused")
        guard preferredFocusIntent != .addressBar else { return }
        preferredFocusIntent = .addressBar
        invalidateSearchFocusRequests(reason: "addressBarFocused")
    }

    func noteFindFieldFocused() {
        clearBrowserFocusMode(reason: "findFieldFocused")
        guard preferredFocusIntent != .findField else { return }
        preferredFocusIntent = .findField
    }

    func canApplySearchFocusRequest(_ generation: UInt64) -> Bool {
        findCoordinator.canApplySearchFocusRequest(generation)
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        if pendingAddressBarFocusRequestId != nil || AppDelegate.shared?.focusedBrowserAddressBarPanelId() == id {
            return .browser(.addressBar)
        }

        if searchState != nil && preferredFocusIntent == .findField {
            return .browser(.findField)
        }

        if let window,
           Self.responderChainContains(window.firstResponder, target: webView) {
            return .browser(.webView)
        }

        return .browser(preferredFocusIntent)
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        if pendingAddressBarFocusRequestId != nil {
            return .browser(.addressBar)
        }
        if searchState != nil && preferredFocusIntent == .findField {
            return .browser(.findField)
        }
        return .browser(preferredFocusIntent)
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        guard case .browser(let target) = intent else { return }

        switch target {
        case .webView:
            preferredFocusIntent = .webView
            invalidateSearchFocusRequests(reason: "prepareWebView")
            endSuppressWebViewFocusForAddressBar()
        case .addressBar:
            clearBrowserFocusMode(reason: "prepareAddressBar")
            preferredFocusIntent = .addressBar
            invalidateSearchFocusRequests(reason: "prepareAddressBar")
            beginSuppressWebViewFocusForAddressBar()
        case .findField:
            clearBrowserFocusMode(reason: "prepareFindField")
            preferredFocusIntent = .findField
        }
#if DEBUG
        cmuxDebugLog(
            "browser.focus.prepare panel=\(id.uuidString.prefix(5)) " +
            "target=\(String(describing: target)) suppressWeb=\(shouldSuppressWebViewFocus() ? 1 : 0)"
        )
#endif
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        guard case .browser(let target) = intent else { return false }

        switch target {
        case .webView:
            noteWebViewFocused()
            focus()
            return true
        case .addressBar:
            let requestId = requestAddressBarFocus(selectionIntent: .preserveFieldEditorSelection)
            NotificationCenter.default.post(name: .browserFocusAddressBar, object: id)
#if DEBUG
            cmuxDebugLog(
                "browser.focus.restore panel=\(id.uuidString.prefix(5)) " +
                "target=addressBar request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return true
        case .findField:
            startFind()
            return true
        }
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        if AppDelegate.shared?.focusedBrowserAddressBarPanelId() == id,
           BrowserOmnibarNativeFieldRegistry.shared.omnibarPanelId(for: responder) == id {
            return .browser(.addressBar)
        }

        if BrowserWindowPortalRegistry.searchOverlayPanelId(for: responder, in: window) == id {
            return .browser(.findField)
        }

        if Self.responderChainContains(responder, target: webView) {
            return .browser(.webView)
        }

        return nil
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard case .browser(let target) = intent else { return false }

        switch target {
        case .findField:
            invalidateSearchFocusRequests(reason: "yieldFindField")
            let yielded = BrowserWindowPortalRegistry.yieldSearchOverlayFocusIfOwned(by: id, in: window)
#if DEBUG
            if yielded {
                cmuxDebugLog("focus.handoff.yield panel=\(id.uuidString.prefix(5)) target=browserFind")
            }
#endif
            return yielded
        case .addressBar:
            guard AppDelegate.shared?.focusedBrowserAddressBarPanelId() == id else { return false }
            guard BrowserOmnibarNativeFieldRegistry.shared.omnibarPanelId(for: window.firstResponder) == id else {
                clearAddressBarFocusTrackingForYield()
                return false
            }
            BrowserOmnibarNativeFieldRegistry.shared.prepareOmnibarForProgrammaticBlur(panelId: id, responder: window.firstResponder)
            clearAddressBarFocusTrackingForYield()
#if DEBUG
            cmuxDebugLog("focus.handoff.yield panel=\(id.uuidString.prefix(5)) target=addressBar")
#endif
            return true
        case .webView:
            guard Self.responderChainContains(window.firstResponder, target: webView) else { return false }
            return window.makeFirstResponder(nil)
        }
    }

    private func clearAddressBarFocusTrackingForYield() {
        endSuppressWebViewFocusForAddressBar()
        AppDelegate.shared?.clearBrowserAddressBarFocus(panelId: id, reason: "yield")
        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: id)
    }

    private func invalidateSearchFocusRequests(reason: String) {
        findCoordinator.invalidateSearchFocusRequests(reason: reason)
    }

    func acknowledgeAddressBarFocusRequest(_ requestId: UUID) {
        guard pendingAddressBarFocusRequestId == requestId else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.requestAck panel=\(id.uuidString.prefix(5)) " +
                "request=\(requestId.uuidString.prefix(8)) result=ignored " +
                "pending=\(pendingAddressBarFocusRequestId?.uuidString.prefix(8) ?? "nil")"
            )
#endif
            return
        }
        pendingAddressBarFocusRequestId = nil
        pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
#if DEBUG
        cmuxDebugLog(
            "browser.focus.addressBar.requestAck panel=\(id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) result=cleared"
        )
#endif
    }

    private func captureAddressBarPageFocusIfNeeded() {
        omnibarPageFocusRepository.captureIfNeeded(panelDebugID: String(id.uuidString.prefix(5)))
    }

    func invalidateAddressBarPageFocusRestoreAttempts() {
        omnibarPageFocusRepository.invalidateRestoreAttempts(panelDebugID: String(id.uuidString.prefix(5)))
    }

    func restoreAddressBarPageFocusIfNeeded(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        omnibarPageFocusRepository.restoreIfNeeded(
            panelDebugID: String(id.uuidString.prefix(5)),
            completion: completion
        )
    }

    /// Returns the most reliable URL string for omnibar-related matching and UI decisions.
    /// `currentURL` can lag behind navigation changes, so prefer the live WKWebView URL.
    func preferredURLStringForOmnibar() -> String? {
        if let webViewURL = BrowserRemoteProxyURLRewriter.displayURL(for: webView.url)?.absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !webViewURL.isEmpty,
           webViewURL != blankURLString {
            return webViewURL
        }

        if let current = currentURL?.absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty,
           current != blankURLString {
            return current
        }

        return nil
    }

    /// Host primitive: the resolved current session-history URL (slice-1
    /// resolver), falling back to the restored current URL.
    func resolvedCurrentSessionHistoryURL() -> URL? {
        Self.sessionHistoryURLResolver.resolvedCurrentURL(
            webViewDisplayURL: BrowserRemoteProxyURLRewriter.displayURL(for: webView.url),
            currentURL: currentURL,
            restoredCurrentURL: restoredHistoryCurrentURL
        )
    }

    private func refreshNavigationAvailability() {
        sessionHistoryCoordinator.refreshNavigationAvailability()
    }

    private func abandonRestoredSessionHistoryIfNeeded() {
        sessionHistoryCoordinator.abandonIfNeeded()
    }

    // MARK: - BrowserSessionHistoryHosting

    // The restored back/forward session-history state machine and its
    // reconciliation/snapshot/restore/traversal flows moved to
    // CmuxBrowser.BrowserSessionHistoryCoordinator. The host primitives below
    // feed it live WebKit state and perform the resolved effects; the live
    // WKWebView back-forward list, the @Published availability, the restored
    // navigation replay, and the #if DEBUG forward-clear log (which names the
    // panel id) stay here as the witness.

    /// Host primitive: the live `backForwardList.backList` URLs, oldest first.
    var nativeBackForwardBackURLs: [URL] {
        webView.backForwardList.backList.map { $0.url }
    }

    /// Host primitive: the live `backForwardList.forwardList` URLs.
    var nativeBackForwardForwardURLs: [URL] {
        webView.backForwardList.forwardList.map { $0.url }
    }

    /// Host primitive: publishes the resolved availability, assigning only on change.
    func setNavigationAvailability(canGoBack: Bool, canGoForward: Bool) {
        if self.canGoBack != canGoBack {
            self.canGoBack = canGoBack
        }
        if self.canGoForward != canGoForward {
            self.canGoForward = canGoForward
        }
    }

    /// Host primitive: replays a restored-history navigation to `url`.
    func navigate(toRestoredSessionHistoryURL url: URL) {
        navigateWithoutInsecureHTTPPrompt(
            to: url,
            recordTypedNavigation: false,
            preserveRestoredSessionHistory: true
        )
    }

    /// Host primitive: emits the restored-history forward-clear debug log.
    func logRestoredSessionHistoryForwardClear(liveCurrentString: String) {
#if DEBUG
        cmuxDebugLog(
            "browser.history.restore.forward.clear panel=\(id.uuidString.prefix(5)) " +
            "current=\(liveCurrentString)"
        )
#endif
    }

    /// Shared resolver mirroring the restored-session-history URL rules, used by
    /// the surface's WebKit-touching resolution helpers. It wraps the sanitizer
    /// whose temporary-URL classification is supplied app-side.
    private static let sessionHistoryURLResolver = BrowserSessionHistoryURLResolver(
        sanitizer: SessionHistoryURLSanitizer {
            $0?.isTemporaryBrowserHistory ?? false
        }
    )

    private static func serializableSessionHistoryURLString(_ url: URL?) -> String? {
        sessionHistoryURLResolver.serializableSessionHistoryURLString(url)
    }

    private static func sanitizedSessionHistoryURL(_ raw: String?) -> URL? {
        sessionHistoryURLResolver.sanitizedSessionHistoryURL(raw)
    }

    private static func sanitizedSessionHistoryURLs(_ values: [String]) -> [URL] {
        sessionHistoryURLResolver.sanitizedSessionHistoryURLs(values)
    }

}

private extension BrowserPanel {
    func applyBrowserThemeModeIfNeeded() {
        BrowserThemeSettings.apply(browserThemeMode, to: webView)
    }

    func scheduleDeveloperToolsRestoreRetry() {
        guard preferredDeveloperToolsVisible else { return }
        guard developerToolsRestoreRetryWorkItem == nil else { return }
        guard developerToolsRestoreRetryAttempt < developerToolsRestoreRetryMaxAttempts else { return }

        developerToolsRestoreRetryAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.developerToolsRestoreRetryWorkItem = nil
            self.restoreDeveloperToolsAfterAttachIfNeeded()
        }
        developerToolsRestoreRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + developerToolsRestoreRetryDelay, execute: work)
    }

    func cancelDeveloperToolsRestoreRetry() {
        developerToolsRestoreRetryWorkItem?.cancel()
        developerToolsRestoreRetryWorkItem = nil
        developerToolsRestoreRetryAttempt = 0
    }
}

#if DEBUG
extension BrowserPanel {
    var downloadDelegateForTesting: BrowserDownloadDelegate? {
        downloadDelegate
    }

    func configureInsecureHTTPAlertHooksForTesting(
        alertFactory: @escaping () -> NSAlert,
        windowProvider: @escaping () -> NSWindow?
    ) {
        insecureHTTPAlertFactory = alertFactory
        insecureHTTPAlertWindowProvider = windowProvider
    }

    func resetInsecureHTTPAlertHooksForTesting() {
        insecureHTTPAlertFactory = { NSAlert() }
        insecureHTTPAlertWindowProvider = { [weak self] in
            if let self, let window = browserInteractiveModalHostWindow(for: self.webView) {
                return window
            }
            return BrowserExternalNavigationPresenter.fallbackInteractiveModalHostWindow()
        }
    }

    func presentInsecureHTTPAlertForTesting(
        url: URL,
        recordTypedNavigation: Bool = false
    ) {
        presentInsecureHTTPAlert(
            for: URLRequest(url: url),
            intent: .currentTab,
            recordTypedNavigation: recordTypedNavigation
        )
    }

    private static func debugRectDescription(_ rect: NSRect) -> String {
        String(
            format: "%.1f,%.1f %.1fx%.1f",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    private static func debugObjectToken(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private static func debugInspectorSubviewCount(in root: NSView) -> Int {
        var stack: [NSView] = [root]
        var count = 0
        while let current = stack.popLast() {
            for subview in current.subviews {
                if subview.isCmuxWebInspectorObject {
                    count += 1
                }
                stack.append(subview)
            }
        }
        return count
    }

    func debugDeveloperToolsStateSummary() -> String {
        let preferred = preferredDeveloperToolsVisible ? 1 : 0
        let visible = isDeveloperToolsVisible() ? 1 : 0
        let inspector = webView.cmuxInspectorObject() == nil ? 0 : 1
        let attached = webView.superview == nil ? 0 : 1
        let inWindow = webView.window == nil ? 0 : 1
        let forceRefresh = forceDeveloperToolsRefreshOnNextAttach ? 1 : 0
        let transitionTarget = developerToolsTransitionTargetVisible.map { $0 ? "1" : "0" } ?? "nil"
        let pendingTarget = pendingDeveloperToolsTransitionTargetVisible.map { $0 ? "1" : "0" } ?? "nil"
        return "pref=\(preferred) vis=\(visible) inspector=\(inspector) attached=\(attached) inWindow=\(inWindow) restoreRetry=\(developerToolsRestoreRetryAttempt) forceRefresh=\(forceRefresh) tx=\(transitionTarget) pending=\(pendingTarget)"
    }

    func debugDeveloperToolsGeometrySummary() -> String {
        let container = webView.superview
        let containerBounds = container?.bounds ?? .zero
        let webFrame = webView.frame
        let inspectorInsets = max(0, containerBounds.height - webFrame.height)
        let inspectorOverflow = max(0, webFrame.maxY - containerBounds.maxY)
        let inspectorHeightApprox = max(inspectorInsets, inspectorOverflow)
        let inspectorSubviews = container.map { Self.debugInspectorSubviewCount(in: $0) } ?? 0
        let containerType = container.map { String(describing: type(of: $0)) } ?? "nil"
        return "webFrame=\(Self.debugRectDescription(webFrame)) webBounds=\(Self.debugRectDescription(webView.bounds)) webWin=\(webView.window?.windowNumber ?? -1) super=\(Self.debugObjectToken(container)) superType=\(containerType) superBounds=\(Self.debugRectDescription(containerBounds)) inspectorHApprox=\(String(format: "%.1f", inspectorHeightApprox)) inspectorInsets=\(String(format: "%.1f", inspectorInsets)) inspectorOverflow=\(String(format: "%.1f", inspectorOverflow)) inspectorSubviews=\(inspectorSubviews)"
    }

}
#endif

private extension BrowserPanel {
    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }

    func hasSideDockedDeveloperToolsLayout() -> Bool {
        guard let container = webView.superview else { return false }
        return Self.visibleDescendants(in: container)
            .filter { Self.isVisibleSideDockInspectorCandidate($0) && Self.isInspectorView($0) }
            .contains { inspectorCandidate in
                hasSideDockedInspectorSibling(startingAt: inspectorCandidate, root: container)
            }
    }

    func hasSideDockedInspectorSibling(startingAt inspectorLeaf: NSView, root: NSView) -> Bool {
        var current: NSView? = inspectorLeaf

        while let inspectorView = current, inspectorView !== root {
            guard let containerView = inspectorView.superview else { break }
            let hasSideDockedSibling = containerView.subviews.contains { candidate in
                guard Self.isVisibleSideDockSiblingCandidate(candidate) else { return false }
                guard candidate !== inspectorView else { return false }
                let horizontallyAdjacent =
                    candidate.frame.maxX <= inspectorView.frame.minX + 1 ||
                    candidate.frame.minX >= inspectorView.frame.maxX - 1
                guard horizontallyAdjacent else { return false }
                return Self.verticalOverlap(between: candidate.frame, and: inspectorView.frame) > 8
            }
            if hasSideDockedSibling {
                return true
            }

            current = containerView
        }

        return false
    }

    static func visibleDescendants(in root: NSView) -> [NSView] {
        var descendants: [NSView] = []
        var stack = Array(root.subviews.reversed())
        while let view = stack.popLast() {
            descendants.append(view)
            stack.append(contentsOf: view.subviews.reversed())
        }
        return descendants
    }

    static func isInspectorView(_ view: NSView) -> Bool {
        view.isCmuxWebInspectorObject
    }

    static func isVisibleSideDockInspectorCandidate(_ view: NSView) -> Bool {
        !view.isHidden &&
            view.alphaValue > 0 &&
            view.frame.width > 1 &&
            view.frame.height > 1
    }

    static func isVisibleSideDockSiblingCandidate(_ view: NSView) -> Bool {
        !view.isHidden &&
            view.alphaValue > 0 &&
            view.frame.width > 1 &&
            view.frame.height > 1
    }

    static func verticalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }
}

extension BrowserPanel {
    func hideBrowserPortalView(source: String) {
        noteWebViewVisibility(
            false,
            reason: "portal.\(source)",
            recordIfUnchanged: true
        )
        BrowserWindowPortalRegistry.hide(
            webView: webView,
            source: source
        )
    }
}

extension WKWebView {
    func cmuxInspectorObject() -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard responds(to: selector),
              let inspector = perform(selector)?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        return inspector
    }

    func cmuxInspectorFrontendWebView() -> WKWebView? {
        guard let inspector = cmuxInspectorObject() else { return nil }
        let selector = NSSelectorFromString("inspectorWebView")
        guard inspector.responds(to: selector),
              let inspectorWebView = inspector.perform(selector)?.takeUnretainedValue() as? WKWebView else {
            return nil
        }
        return inspectorWebView
    }
}

@MainActor
enum WebViewInspectorTeardown {
    @discardableResult
    static func closeAllInspectors(in window: NSWindow) -> Int {
        assert(Thread.isMainThread)

        return webViews(in: window).reduce(0) { count, webView in
            closeInspector(for: webView) ? count + 1 : count
        }
    }

    @discardableResult
    static func closeAllInspectors(in windows: [NSWindow]) -> Int {
        windows.reduce(0) { count, window in
            count + closeAllInspectors(in: window)
        }
    }

    @discardableResult
    static func closeInspector(for webView: WKWebView) -> Bool {
        assert(Thread.isMainThread)

        guard !isInspectorFrontendWebView(webView),
              let inspector = webView.cmuxInspectorObject() else {
            return false
        }

        let isVisibleSelector = NSSelectorFromString("isVisible")
        let isAttachedSelector = NSSelectorFromString("isAttached")
        let isVisible = inspector.cmuxCallBool(selector: isVisibleSelector)
        let isAttached = inspector.cmuxCallBool(selector: isAttachedSelector)
        let shouldClose = (isVisible == true)
            || (isAttached == true)
            || (isVisible == nil && isAttached == nil)
        guard shouldClose else { return false }

        // cmux already opens Web Inspector through WebKit's `_inspector` object
        // because the deployable SDK surface does not expose a stable close API.
        // Keep teardown on the same auditable SPI path so WebKit unregisters the
        // inspector window observers before the parent AppKit close cascade runs.
        let closeSelector = NSSelectorFromString("close")
        guard inspector.responds(to: closeSelector) else { return false }
        inspector.cmuxCallVoid(selector: closeSelector)
        return true
    }

    private static func webViews(in window: NSWindow) -> [WKWebView] {
        var seen = Set<ObjectIdentifier>()
        var result: [WKWebView] = []
        let roots = [window.contentView, window.contentView?.superview].compactMap { $0 }
        for root in roots {
            collectWebViews(in: root, seen: &seen, result: &result)
        }
        return result
    }

    private static func collectWebViews(
        in view: NSView,
        seen: inout Set<ObjectIdentifier>,
        result: inout [WKWebView]
    ) {
        if let webView = view as? WKWebView,
           !isInspectorFrontendWebView(webView) {
            let id = ObjectIdentifier(webView)
            if !seen.contains(id) {
                seen.insert(id)
                result.append(webView)
            }
        }

        for subview in view.subviews {
            collectWebViews(in: subview, seen: &seen, result: &result)
        }
    }

    private static func isInspectorFrontendWebView(_ webView: WKWebView) -> Bool {
        webView.isCmuxWebInspectorObject
    }
}

private extension NSObject {
    func cmuxCallBool(selector: Selector) -> Bool? {
        guard responds(to: selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        return fn(self, selector)
    }

    func cmuxCallVoid(selector: Selector) {
        guard responds(to: selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
    }
}

// MARK: - Download Delegate

/// Handles WKDownload lifecycle by saving to a temp file synchronously (no UI
/// during WebKit callbacks), then moving the finished file to the user's
/// Downloads folder unless the browser save-panel setting is enabled.
class BrowserDownloadDelegate: NSObject, WKDownloadDelegate {
    private nonisolated static let maxDownloadDestinationCollisionRetries = 100

    private struct DownloadState: Sendable {
        let downloadID: String
        let tempURL: URL
        let suggestedFilename: String
        let sourceURL: URL
    }

    /// Tracks active downloads keyed by WKDownload identity.
    private var activeDownloads: [ObjectIdentifier: DownloadState] = [:]
    private var suggestedFilenameOverrides: [ObjectIdentifier: String] = [:]
    private let activeDownloadsLock = NSLock()
    var onDownloadStarted: ((String, String) -> Void)?
    var onDownloadReadyToSave: ((String, String) -> Void)?
    var onDownloadSaved: ((String, URL, Bool, String) -> Void)?
    var onDownloadCancelled: ((String, Bool, String) -> Void)?
    var onDownloadFailed: ((Error, Bool, String?) -> Void)?
    var savePanelParentWindow: (() -> NSWindow?)?

    static let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func storeState(_ state: DownloadState, for download: WKDownload) {
        activeDownloadsLock.lock()
        activeDownloads[ObjectIdentifier(download)] = state
        activeDownloadsLock.unlock()
    }

    func setSuggestedFilenameOverride(_ suggestedFilename: String?, for download: WKDownload) {
        let trimmed = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return }
        activeDownloadsLock.lock()
        suggestedFilenameOverrides[ObjectIdentifier(download)] = trimmed
        activeDownloadsLock.unlock()
    }

    private func takeSuggestedFilenameOverride(for download: WKDownload) -> String? {
        activeDownloadsLock.lock()
        let filename = suggestedFilenameOverrides.removeValue(forKey: ObjectIdentifier(download))
        activeDownloadsLock.unlock()
        return filename
    }

    private func removeState(for download: WKDownload) -> DownloadState? {
        activeDownloadsLock.lock()
        let state = activeDownloads.removeValue(forKey: ObjectIdentifier(download))
        suggestedFilenameOverrides.removeValue(forKey: ObjectIdentifier(download))
        activeDownloadsLock.unlock()
        return state
    }

    private func notifyOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    nonisolated static func moveTemporaryDownloadToDownloads(
        tempURL: URL,
        suggestedFilename: String,
        sourceURL: URL,
        filenameResolver: BrowserDownloadFilenameResolver,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = filenameResolver.downloadsDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        try tempURL.cmuxApplyWebDownloadQuarantine(sourceURL: sourceURL)
        var lastCollisionError: Error?
        for _ in 0..<Self.maxDownloadDestinationCollisionRetries {
            let destinationURL = filenameResolver.uniqueDownloadDestination(
                suggestedFilename: suggestedFilename,
                in: directory,
                fileManager: fileManager
            )
            do {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
                return destinationURL
            } catch {
                guard fileManager.fileExists(atPath: destinationURL.path) else {
                    throw error
                }
                lastCollisionError = error
            }
        }
        throw lastCollisionError ?? CocoaError(.fileWriteUnknown)
    }

    @MainActor
    func presentSavePanel(
        downloadID: String,
        tempURL: URL,
        suggestedFilename: String,
        sourceURL: URL,
        filenameResolver: BrowserDownloadFilenameResolver
    ) {
        onDownloadReadyToSave?(suggestedFilename, downloadID)
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = suggestedFilename
        savePanel.canCreateDirectories = true
        savePanel.directoryURL = filenameResolver.downloadsDirectory()
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard result == .OK, let destURL = savePanel.url else {
                try? FileManager.default.removeItem(at: tempURL)
                self?.onDownloadCancelled?(suggestedFilename, false, downloadID)
                return
            }
            do {
                try tempURL.cmuxApplyWebDownloadQuarantine(sourceURL: sourceURL)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    _ = try FileManager.default.replaceItemAt(destURL, withItemAt: tempURL)
                } else {
                    try FileManager.default.moveItem(at: tempURL, to: destURL)
                }
                try? destURL.cmuxApplyWebDownloadQuarantine(sourceURL: sourceURL); self?.onDownloadSaved?(suggestedFilename, destURL, false, downloadID)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                self?.onDownloadFailed?(error, false, downloadID)
            }
        }
        if let parentWindow = savePanelParentWindow?() {
            savePanel.beginSheetModal(for: parentWindow, completionHandler: completion)
        } else {
            savePanel.begin(completionHandler: completion)
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        // Save to a temp file — return synchronously so WebKit is never blocked.
        let filenameResolver = BrowserDownloadFilenameResolver()
        if case .reject = filenameResolver.httpStatusDecision(for: response) {
            _ = removeState(for: download)
            completionHandler(nil)
            return
        }
        let preferredSuggestedFilename = takeSuggestedFilenameOverride(for: download) ?? suggestedFilename
        let sourceURL = response.url ?? URL(fileURLWithPath: suggestedFilename)
        let safeFilename = filenameResolver.suggestedFilename(suggestedFilename: preferredSuggestedFilename, response: response, sourceURL: sourceURL, imageType: nil)
        let tempFilename = "\(UUID().uuidString)-\(safeFilename)"
        let destURL = Self.tempDir.appendingPathComponent(tempFilename, isDirectory: false)
        let downloadID = UUID().uuidString
        try? FileManager.default.removeItem(at: destURL)
        storeState(DownloadState(downloadID: downloadID, tempURL: destURL, suggestedFilename: safeFilename, sourceURL: sourceURL), for: download)
        notifyOnMain { [weak self] in
            self?.onDownloadStarted?(safeFilename, downloadID)
        }
        #if DEBUG
        cmuxDebugLog("download.decideDestination file=<redacted>")
        #endif
        completionHandler(destURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let info = removeState(for: download) else {
            #if DEBUG
            cmuxDebugLog("download.finished missing-state")
            #endif
            return
        }
        #if DEBUG
        cmuxDebugLog("download.finished file=<redacted>")
        #endif
        let filenameResolver = BrowserDownloadFilenameResolver()
        Task { @MainActor in
            let imageType = await Task.detached(priority: .utility) {
                filenameResolver.imageType(forDownloadedFileAt: info.tempURL)
            }.value
            let suggestedFilename = filenameResolver.suggestedFilename(suggestedFilename: info.suggestedFilename, response: nil, sourceURL: info.sourceURL, imageType: imageType)

            if filenameResolver.shouldAskWhereToSaveDownloads() {
                self.presentSavePanel(
                    downloadID: info.downloadID,
                    tempURL: info.tempURL,
                    suggestedFilename: suggestedFilename,
                    sourceURL: info.sourceURL,
                    filenameResolver: filenameResolver
                )
                return
            }

            let saveResult = await Task.detached(priority: .utility) {
                Result {
                    try Self.moveTemporaryDownloadToDownloads(
                        tempURL: info.tempURL,
                        suggestedFilename: suggestedFilename,
                        sourceURL: info.sourceURL,
                        filenameResolver: filenameResolver
                    )
                }
            }.value
            switch saveResult {
            case .success(let destinationURL):
                self.onDownloadSaved?(suggestedFilename, destinationURL, true, info.downloadID)
                #if DEBUG
                cmuxDebugLog("download.saved path=<redacted>")
                #endif
            case .failure(let error):
                try? FileManager.default.removeItem(at: info.tempURL)
                self.onDownloadFailed?(error, true, info.downloadID)
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let downloadID: String?
        if let info = removeState(for: download) {
            try? FileManager.default.removeItem(at: info.tempURL)
            downloadID = info.downloadID
        } else {
            downloadID = nil
        }
        notifyOnMain { [weak self] in
            self?.onDownloadFailed?(error, true, downloadID)
        }
        #if DEBUG
        cmuxDebugLog("download.failed error=\(error.localizedDescription)")
        #endif
        NSLog("BrowserPanel download failed: %@", error.localizedDescription)
    }
}

// MARK: - UI Delegate

private class BrowserUIDelegate: BrowserPDFPreviewActionUIDelegate {
    var openInNewTab: ((URL) -> Void)?
    var requestNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    var presentAlert: BrowserAlertPresenter = browserPresentAlert
    var openPopup: ((WKWebViewConfiguration, WKWindowFeatures) -> WKWebView?)?
    var closeRequested: ((WKWebView) -> Void)?

    func webViewDidClose(_ webView: WKWebView) {
        closeRequested?(webView)
    }

    private func javaScriptDialogTitle(for webView: WKWebView) -> String {
        if let absolute = webView.url?.absoluteString, !absolute.isEmpty {
            return String(localized: "browser.dialog.pageSaysAt", defaultValue: "The page at \(absolute) says:")
        }
        return String(localized: "browser.dialog.pageSays", defaultValue: "This page says:")
    }

    private func presentDialog(
        _ alert: NSAlert,
        for webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void,
        cancel: @escaping () -> Void
    ) {
        presentAlert(alert, webView, completion, cancel)
    }

    /// Called when the page requests a new window (window.open(), target=_blank, etc.).
    ///
    /// Returns a live popup WKWebView created with WebKit's supplied configuration
    /// to preserve popup browsing-context semantics (window.opener, postMessage).
    /// Falls back to new-tab behavior only if popup creation is unavailable.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
#if DEBUG
        let currentEventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
        let currentEventButton = NSApp.currentEvent.map { String($0.buttonNumber) } ?? "nil"
        let navType = String(describing: navigationAction.navigationType)
        let requestMethod = navigationAction.request.httpMethod ?? "nil"
        let requestURL = navigationAction.request.url?.absoluteString ?? "nil"
        let targetMainFrame = navigationAction.targetFrame.map { $0.isMainFrame ? "1" : "0" } ?? "nil"
        let windowFeaturesSummary = [
            "x=\(windowFeatures.x?.stringValue ?? "nil")",
            "y=\(windowFeatures.y?.stringValue ?? "nil")",
            "w=\(windowFeatures.width?.stringValue ?? "nil")",
            "h=\(windowFeatures.height?.stringValue ?? "nil")",
            "toolbars=\(windowFeatures.toolbarsVisibility?.stringValue ?? "nil")",
            "resizable=\(windowFeatures.allowsResizing?.stringValue ?? "nil")",
            "status=\(windowFeatures.statusBarVisibility?.stringValue ?? "nil")",
            "menu=\(windowFeatures.menuBarVisibility?.stringValue ?? "nil")"
        ].joined(separator: ",")
        cmuxDebugLog(
            "browser.nav.createWebView navType=\(navType) button=\(navigationAction.buttonNumber) " +
            "mods=\(navigationAction.modifierFlags.rawValue) targetNil=\(navigationAction.targetFrame == nil ? 1 : 0) " +
            "targetMain=\(targetMainFrame) method=\(requestMethod) url=\(requestURL) " +
            "eventType=\(currentEventType) eventButton=\(currentEventButton) " +
            "windowFeatures={\(windowFeaturesSummary)}"
        )
#endif
        let popupFeaturesWereSpecified = BrowserPopupWindowFeatures(windowFeatures: windowFeatures).wereSpecified
        let decision = BrowserCreateWebViewDecision.resolve(
            request: navigationAction.request,
            openerURL: webView.url,
            popupFeaturesWereSpecified: popupFeaturesWereSpecified,
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            hasRecentMiddleClickIntent: CmuxWebView.hasRecentMiddleClickIntent(for: webView),
            currentEventType: NSApp.currentEvent?.type,
            currentEventButtonNumber: NSApp.currentEvent?.buttonNumber
        )

        // External URL schemes → hand off to macOS, don't create a popup
        if case .routeExternally(let url) = decision {
            browserHandleExternalNavigation(
                url,
                source: "uiDelegate",
                webView: webView,
                loadFallbackRequest: { [requestNavigation] request in
                    requestNavigation?(request, .currentTab)
                },
                presentAlert: presentAlert
            )
            return nil
        }

        if case .openInCurrentTab(let request) = decision {
            if let url = request.url {
#if DEBUG
                cmuxDebugLog(
                    "browser.nav.createWebView.action kind=requestNavigationSimpleUserGesture intent=currentTab " +
                    "url=\(browserNavigationDebugURL(url))"
                )
#endif
                if let requestNavigation {
                    requestNavigation(request, .currentTab)
                } else {
                    webView.browserLoadRequest(request)
                }
            }
            return nil
        }

        if case .createPopup = decision, let popupWebView = openPopup?(configuration, windowFeatures) {
#if DEBUG
            cmuxDebugLog("browser.nav.createWebView.action kind=popup")
#endif
            return popupWebView
        }

        // Fallback: open in new tab (no opener linkage). Covers .openInNewTab and
        // a scripted popup whose openPopup closure was unavailable.
        if let url = navigationAction.request.url {
            if let requestNavigation {
                let intent: BrowserInsecureHTTPNavigationIntent = .newTab
#if DEBUG
                cmuxDebugLog(
                    "browser.nav.createWebView.action kind=requestNavigation intent=newTab " +
                    "url=\(browserNavigationDebugURL(url))"
                )
#endif
                requestNavigation(navigationAction.request, intent)
            } else {
#if DEBUG
                cmuxDebugLog("browser.nav.createWebView.action kind=openInNewTab url=\(url.absoluteString)")
#endif
                openInNewTab?(url)
            }
        }
        return nil
    }

    /// Handle <input type="file"> elements by presenting the native file picker.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.prompt)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: webView)
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        presentDialog(
            alert,
            for: webView,
            completion: { _ in completionHandler() },
            cancel: completionHandler
        )
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: webView)
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        presentDialog(
            alert,
            for: webView,
            completion: { response in
                completionHandler(response == .alertFirstButtonReturn)
            },
            cancel: {
                completionHandler(false)
            }
        )
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: webView)
        alert.informativeText = prompt
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field

        presentDialog(
            alert,
            for: webView,
            completion: { response in
                if response == .alertFirstButtonReturn {
                    completionHandler(field.stringValue)
                } else {
                    completionHandler(nil)
                }
            },
            cancel: {
                completionHandler(nil)
            }
        )
    }
}

// MARK: - Browser Data Import

// The import plan value types, resolver, error, and profile seam now live in
// CmuxBrowser (Import/Resolution + Import/Values). The app supplies the
// destination-profile store and the app-bundle-localized failure strings.

extension BrowserProfileStore: @retroactive BrowserImportProfileProvisioning {}

extension BrowserImportRealizationStrings {
    /// App-bundle-localized realization failure messages.
    ///
    /// Localization stays app-side: resolving these with `String(localized:)`
    /// inside CmuxBrowser would bind to the package bundle and drop the Japanese
    /// (and any future) translation, so the app resolves them and passes them
    /// through the seam.
    @MainActor
    static var appLocalized: BrowserImportRealizationStrings {
        BrowserImportRealizationStrings(
            destinationMissing: String(
                localized: "browser.import.error.destinationMissing",
                defaultValue: "The selected cmux browser profile no longer exists. Pick a destination profile again."
            ),
            destinationCreateFailedFormat: String(
                localized: "browser.import.error.destinationCreateFailed",
                defaultValue: "cmux could not create the destination profile \"%@\"."
            )
        )
    }
}

extension BrowserImportPlanResolver {
    /// Realizes a plan against the shared profile store, resolving failure
    /// messages in the app bundle.
    @MainActor
    func realize(
        plan: BrowserImportExecutionPlan,
        profileStore: BrowserProfileStore? = nil
    ) throws -> RealizedBrowserImportExecutionPlan {
        try realize(
            plan: plan,
            profileProvider: profileStore ?? BrowserProfileStore.shared,
            strings: .appLocalized
        )
    }
}

// The cookie/history import engine now lives in CmuxBrowser
// (Import/Engine/BrowserDataImportService). The app supplies the destination
// cookie/history sink and the app-bundle-localized warning strings.

extension BrowserProfileStore: @retroactive BrowserImportProfileDataWriting {
    public func httpCookieStore(forProfileID profileID: UUID) -> WKHTTPCookieStore {
        websiteDataStore(for: profileID).httpCookieStore
    }

    public func mergeImportedHistory(_ entries: [BrowserHistoryEntry], intoProfileID profileID: UUID) -> Int {
        historyStore(for: profileID).mergeImportedEntries(entries)
    }
}

extension BrowserImportWarningStrings {
    /// App-bundle-localized import warning templates.
    ///
    /// Localization stays app-side: resolving these with `String(localized:)`
    /// inside CmuxBrowser would bind to the package bundle and drop the Japanese
    /// (and any future) translation, so the app resolves them and passes them
    /// through the seam.
    @MainActor
    static var appLocalized: BrowserImportWarningStrings {
        BrowserImportWarningStrings(
            additionalDataUnavailable: String(
                localized: "browser.import.warning.additionalDataUnavailable",
                defaultValue: "Bookmarks, settings, and extensions import are not available yet. Imported cookies and history only."
            ),
            safariCookiesUnsupported: String(
                localized: "browser.import.warning.safariCookiesUnsupported",
                defaultValue: "Safari cookies are stored in Cookies.binarycookies and are not yet supported by this importer."
            ),
            cookieImportUnsupportedFormat: String(
                localized: "browser.import.warning.cookieImportUnsupported",
                defaultValue: "%@ cookie import is not implemented yet."
            ),
            firefoxCookiesReadFailedFormat: String(
                localized: "browser.import.warning.firefoxCookiesReadFailed",
                defaultValue: "Failed reading Firefox cookies at %@: %@"
            ),
            browserCookiesReadFailedFormat: String(
                localized: "browser.import.warning.browserCookiesReadFailed",
                defaultValue: "Failed reading %@ cookies at %@: %@"
            ),
            firefoxHistoryReadFailedFormat: String(
                localized: "browser.import.warning.firefoxHistoryReadFailed",
                defaultValue: "Failed reading Firefox history at %@: %@"
            ),
            browserHistoryReadFailedFormat: String(
                localized: "browser.import.warning.browserHistoryReadFailed",
                defaultValue: "Failed reading %@ history at %@: %@"
            ),
            noHistoryDatabaseFormat: String(
                localized: "browser.import.warning.noHistoryDatabase",
                defaultValue: "No history database found for %@."
            ),
            keychainDecryptFailedFormat: String(
                localized: "browser.import.warning.keychainDecryptFailed",
                defaultValue: "Skipped %ld encrypted %@ cookies because %@ could not be unlocked from Keychain."
            ),
            encryptedCookiesSkippedFormat: String(
                localized: "browser.import.warning.encryptedCookiesSkipped",
                defaultValue: "Skipped %ld encrypted cookies that require Keychain decryption."
            )
        )
    }
}

@MainActor
final class BrowserDataImportCoordinator {
    static let shared = BrowserDataImportCoordinator()

    private var importInProgress = false

    /// Held detector instance; the coordinator detects and summarizes installed
    /// browsers through this rather than the former `BrowserInstalledBrowserDetector`
    /// static namespace.
    private let installedBrowserDetector = BrowserInstalledBrowserDetector()

    private init() {}

    func presentImportDialog(
        defaultDestinationProfileID: UUID? = nil,
        defaultScope: BrowserImportScope? = nil
    ) {
        presentImportDialog(
            prefilledBrowsers: nil,
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope
        )
    }

    private struct ImportSelection {
        let browser: InstalledBrowserCandidate
        let executionPlan: BrowserImportExecutionPlan
        let scope: BrowserImportScope
        let domainFilters: [String]
    }

    private func presentImportDialog(
        prefilledBrowsers: [InstalledBrowserCandidate]?,
        defaultDestinationProfileID: UUID?,
        defaultScope: BrowserImportScope?
    ) {
        guard !importInProgress else { return }
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let fixtureLoader = BrowserImportUITestFixtureLoader()
        let fixtureBrowsers = fixtureLoader.browsers(from: environment)
        let fixtureDestinationProfiles = fixtureLoader.destinationProfiles(from: environment)
        let browsers = prefilledBrowsers ?? fixtureBrowsers ?? installedBrowserDetector.detectInstalledBrowsers()
#else
        let fixtureDestinationProfiles: [BrowserProfileDefinition]? = nil
        let browsers = prefilledBrowsers ?? installedBrowserDetector.detectInstalledBrowsers()
#endif
        guard !browsers.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                localized: "browser.import.noBrowsers.title",
                defaultValue: "No importable browsers found"
            )
            alert.informativeText = String(
                localized: "browser.import.noBrowsers.message",
                defaultValue: "cmux could not find browser profiles to import from on this Mac."
            )
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            alert.runModal()
            return
        }

        guard let selection = promptForSelection(
            browsers: browsers,
            destinationProfiles: fixtureDestinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope
        ) else { return }

#if DEBUG
        if captureSelectionIfRequested(selection, destinationProfiles: fixtureDestinationProfiles) {
            return
        }
#endif
        let realizedPlan: RealizedBrowserImportExecutionPlan
        do {
            realizedPlan = try BrowserImportPlanResolver().realize(plan: selection.executionPlan)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                localized: "browser.import.error.title",
                defaultValue: "Import could not start"
            )
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            alert.runModal()
            return
        }
        importInProgress = true

        let progressWindow = showProgressWindow(
            title: String(
                localized: "browser.import.progress.title",
                defaultValue: "Importing Browser Data"
            ),
            message: String(
                format: String(
                    localized: "browser.import.progress.message",
                    defaultValue: "Importing %@ from %@…"
                ),
                selection.scope.displayName.lowercased(),
                selection.browser.displayName
            )
        )

        let importService = BrowserDataImportService(
            sink: BrowserProfileStore.shared,
            strings: .appLocalized
        )
        Task.detached(priority: .userInitiated) {
            let outcome = await importService.importData(
                from: selection.browser,
                plan: realizedPlan,
                scope: selection.scope,
                domainFilters: selection.domainFilters
            )

            await MainActor.run {
                self.hideProgressWindow(progressWindow)
                self.presentOutcome(outcome)
                self.importInProgress = false
            }
        }
    }

    private func promptForSelection(
        browsers: [InstalledBrowserCandidate],
        destinationProfiles: [BrowserProfileDefinition]?,
        defaultDestinationProfileID: UUID?,
        defaultScope: BrowserImportScope?
    ) -> ImportSelection? {
        guard !browsers.isEmpty else { return nil }
        let wizard = ImportWizardWindowController(
            browsers: browsers,
            destinationProfiles: destinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope
        )
        return wizard.runModal()
    }

#if DEBUG
    func debugMakeImportWizardWindow(
        browsers: [InstalledBrowserCandidate],
        destinationProfiles: [BrowserProfileDefinition]? = nil,
        defaultDestinationProfileID: UUID? = nil,
        defaultScope: BrowserImportScope? = nil
    ) -> NSWindow {
        let wizard = ImportWizardWindowController(
            browsers: browsers,
            destinationProfiles: destinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope
        )
        return wizard.debugPanelWindow
    }
#endif

#if DEBUG
    private struct CapturedImportSelection: Encodable {
        struct Entry: Encodable {
            let sourceProfiles: [String]
            let destinationKind: String
            let destinationName: String
        }

        let browserName: String
        let mode: String
        let scope: String
        let domainFilters: [String]
        let entries: [Entry]
    }

    private func captureSelectionIfRequested(
        _ selection: ImportSelection,
        destinationProfiles: [BrowserProfileDefinition]?
    ) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_UI_TEST_BROWSER_IMPORT_MODE"] == "capture-only" else { return false }
        guard let path = environment["CMUX_UI_TEST_BROWSER_IMPORT_CAPTURE_PATH"], !path.isEmpty else {
            return true
        }

        let availableDestinationProfiles = destinationProfiles ?? BrowserProfileStore.shared.profiles
        let payload = CapturedImportSelection(
            browserName: selection.browser.displayName,
            mode: captureModeName(selection.executionPlan.mode),
            scope: selection.scope.rawValue,
            domainFilters: selection.domainFilters,
            entries: selection.executionPlan.entries.map { entry in
                let destinationKind: String
                let destinationName: String
                switch entry.destination {
                case .existing(let id):
                    destinationKind = "existing"
                    destinationName = availableDestinationProfiles.first(where: { $0.id == id })?.displayName
                        ?? BrowserProfileStore.shared.displayName(for: id)
                case .createNamed(let name):
                    destinationKind = "create"
                    destinationName = name
                }
                return CapturedImportSelection.Entry(
                    sourceProfiles: entry.sourceProfiles.map(\.displayName),
                    destinationKind: destinationKind,
                    destinationName: destinationName
                )
            }
        )

        guard let data = try? JSONEncoder().encode(payload) else { return true }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? data.write(to: url)
        return true
    }

    private func captureModeName(_ mode: BrowserImportDestinationMode) -> String {
        switch mode {
        case .singleDestination:
            return "singleDestination"
        case .separateProfiles:
            return "separateProfiles"
        case .mergeIntoOne:
            return "mergeIntoOne"
        }
    }
#endif

    @MainActor
    private final class ImportWizardWindowController: NSObject, NSWindowDelegate {
        private final class FlippedDocumentView: NSView {
            override var isFlipped: Bool { true }
        }

        private enum Step {
            case source
            case sourceProfiles
            case dataTypes
        }

        private let browsers: [InstalledBrowserCandidate]
        private let destinationProfiles: [BrowserProfileDefinition]
        private let initialDestinationProfileID: UUID
        private let defaultScope: BrowserImportScope?
        /// Held detector instance used to summarize the detected browsers, rather
        /// than the former `BrowserInstalledBrowserDetector` static namespace.
        private let installedBrowserDetector = BrowserInstalledBrowserDetector()

        private var step: Step = .source
        private var didFinishModal = false
        private(set) var selection: ImportSelection?
        private var selectedSourceProfileIDsByBrowserID: [String: Set<String>] = [:]
        private var sourceProfileCheckboxes: [NSButton] = []
        private var destinationMode: BrowserImportDestinationMode = .singleDestination
        private var separateExecutionEntries: [BrowserImportExecutionEntry] = []
        private var separateDestinationOptionsByEntryIndex: [Int: [BrowserImportDestinationRequest]] = [:]
        private var mergeDestinationProfileID: UUID

        private let panel: NSPanel

        private let stepLabel = NSTextField(labelWithString: "")
        private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        private let sourceContainer = NSStackView()
        private let sourceProfilesContainer = NSStackView()
        private let sourceProfilesList = NSStackView()
        private let sourceProfilesDocumentView = FlippedDocumentView(frame: .zero)
        private let sourceProfilesEmptyLabel = NSTextField(wrappingLabelWithString: "")
        private let sourceProfilesHelpLabel = NSTextField(labelWithString: "")
        private let sourceProfilesScrollView = NSScrollView()
        private var sourceProfilesScrollHeightConstraint: NSLayoutConstraint?
        private let dataTypesContainer = NSStackView()
        private let validationLabel = NSTextField(labelWithString: "")
        private let destinationModeContainer = NSStackView()
        private let separateProfilesRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
        private let mergeProfilesRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
        private let separateDestinationRows = NSStackView()
        private let mergeDestinationRow = NSStackView()
        private let mergeDestinationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        private let destinationHelpLabel = NSTextField(wrappingLabelWithString: "")
        private let additionalDataNoteLabel = NSTextField(wrappingLabelWithString: "")

        private let cookiesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        private let historyCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        private let additionalDataCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        private let domainField = NSTextField(frame: .zero)

        private let backButton = NSButton(title: "", target: nil, action: nil)
        private let cancelButton = NSButton(title: "", target: nil, action: nil)
        private let primaryButton = NSButton(title: "", target: nil, action: nil)

        init(
            browsers: [InstalledBrowserCandidate],
            destinationProfiles: [BrowserProfileDefinition]?,
            defaultDestinationProfileID: UUID?,
            defaultScope: BrowserImportScope?
        ) {
            let resolvedDestinationProfiles = destinationProfiles ?? BrowserProfileStore.shared.profiles
            let fallbackDestinationProfileID = resolvedDestinationProfiles.first?.id
                ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
            self.browsers = browsers
            self.destinationProfiles = resolvedDestinationProfiles
            self.initialDestinationProfileID = defaultDestinationProfileID
                .flatMap { candidateID in resolvedDestinationProfiles.first(where: { $0.id == candidateID })?.id }
                ?? fallbackDestinationProfileID
            self.defaultScope = defaultScope
            self.mergeDestinationProfileID = self.initialDestinationProfileID
            self.panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 292),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            super.init()
            setupUI()
            configureInitialState()
        }

        func runModal() -> ImportSelection? {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            let response = NSApp.runModal(for: panel)
            if panel.isVisible {
                panel.orderOut(nil)
            }

            guard response == .OK else { return nil }
            return selection
        }

#if DEBUG
        var debugPanelWindow: NSWindow { panel }
#endif

        func windowWillClose(_ notification: Notification) {
            finishModal(with: .cancel)
        }

        @objc
        private func handleBack() {
            switch step {
            case .source:
                return
            case .sourceProfiles:
                step = .source
            case .dataTypes:
                step = .sourceProfiles
            }
            validationLabel.isHidden = true
            updateStepUI()
        }

        @objc
        private func handleCancel() {
            finishModal(with: .cancel)
        }

        @objc
        private func handlePrimary() {
            switch step {
            case .source:
                step = .sourceProfiles
                validationLabel.isHidden = true
                refreshSourceProfilesList()
                updateStepUI()
            case .sourceProfiles:
                let selectedSourceProfiles = selectedSourceProfiles()
                guard !selectedSourceProfiles.isEmpty else {
                    validationLabel.stringValue = String(
                        localized: "browser.import.validation.sourceProfiles",
                        defaultValue: "Choose at least one source profile to import."
                    )
                    validationLabel.isHidden = false
                    return
                }

                resetStep3State()
                step = .dataTypes
                validationLabel.isHidden = true
                updateStepUI()
            case .dataTypes:
                let includeCookies = cookiesCheckbox.state == .on
                let includeHistory = historyCheckbox.state == .on
                let includeAdditionalData = additionalDataCheckbox.state == .on
                guard let scope = BrowserImportScope.fromSelection(
                    includeCookies: includeCookies,
                    includeHistory: includeHistory,
                    includeAdditionalData: includeAdditionalData
                ) else {
                    validationLabel.stringValue = String(
                        localized: "browser.import.validation.scope",
                        defaultValue: "Select Cookies, History, or both before starting import."
                    )
                    validationLabel.isHidden = false
                    return
                }

                let selectedBrowser = selectedBrowser()
                let domainFilters = BrowserDataImportService.parseDomainFilters(domainField.stringValue)
                selection = ImportSelection(
                    browser: selectedBrowser,
                    executionPlan: currentExecutionPlan(),
                    scope: scope,
                    domainFilters: domainFilters
                )
                finishModal(with: .OK)
            }
        }

        @objc
        private func handleSourceChanged() {
            validationLabel.isHidden = true
            refreshSourceProfilesList()
            updateStepUI()
        }

        @objc
        private func handleSourceProfileToggled(_ sender: NSButton) {
            guard let profileID = sender.identifier?.rawValue else { return }
            let browserID = selectedBrowser().id
            var selectedIDs = storedSelectedSourceProfileIDs(for: selectedBrowser())
            if sender.state == .on {
                selectedIDs.insert(profileID)
            } else {
                selectedIDs.remove(profileID)
            }
            selectedSourceProfileIDsByBrowserID[browserID] = selectedIDs
            validationLabel.isHidden = true
        }

        @objc
        private func handleDestinationModeChanged(_ sender: NSButton) {
            let selectedSourceProfiles = selectedSourceProfiles()
            guard selectedSourceProfiles.count > 1 else { return }
            destinationMode = sender == separateProfilesRadio ? .separateProfiles : .mergeIntoOne
            rebuildStep3DestinationUI()
            updatePanelSize()
        }

        @objc
        private func handleMergeDestinationChanged(_ sender: NSPopUpButton) {
            let selectedIndex = max(0, min(sender.indexOfSelectedItem, destinationProfiles.count - 1))
            guard destinationProfiles.indices.contains(selectedIndex) else { return }
            mergeDestinationProfileID = destinationProfiles[selectedIndex].id
            validationLabel.isHidden = true
        }

        @objc
        private func handleSeparateDestinationChanged(_ sender: NSPopUpButton) {
            let entryIndex = sender.tag
            guard separateExecutionEntries.indices.contains(entryIndex),
                  let options = separateDestinationOptionsByEntryIndex[entryIndex],
                  options.indices.contains(sender.indexOfSelectedItem) else {
                return
            }
            separateExecutionEntries[entryIndex].destination = options[sender.indexOfSelectedItem]
            validationLabel.isHidden = true
        }

        @objc
        private func handleImportOptionChanged(_ sender: NSButton) {
            validationLabel.isHidden = true
            updateAdditionalDataNoteVisibility()
            updatePanelSize()
        }

        private func setupUI() {
            panel.title = String(
                localized: "browser.import.title",
                defaultValue: "Import Browser Data"
            )
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true

            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 292))
            contentView.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView = contentView

            let titleLabel = NSTextField(
                labelWithString: String(
                    localized: "browser.import.title",
                    defaultValue: "Import Browser Data"
                )
            )
            titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

            stepLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            stepLabel.textColor = .secondaryLabelColor

            setupSourceContainer()
            setupSourceProfilesContainer()
            setupDataTypesContainer()

            validationLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            validationLabel.textColor = .systemRed
            validationLabel.isHidden = true
            validationLabel.lineBreakMode = .byWordWrapping
            validationLabel.maximumNumberOfLines = 3
            validationLabel.translatesAutoresizingMaskIntoConstraints = false

            backButton.target = self
            backButton.action = #selector(handleBack)
            backButton.bezelStyle = .rounded
            backButton.title = String(localized: "browser.import.back", defaultValue: "Back")

            cancelButton.target = self
            cancelButton.action = #selector(handleCancel)
            cancelButton.bezelStyle = .rounded
            cancelButton.title = String(localized: "common.cancel", defaultValue: "Cancel")
            cancelButton.keyEquivalent = "\u{1b}"

            primaryButton.target = self
            primaryButton.action = #selector(handlePrimary)
            primaryButton.bezelStyle = .rounded
            primaryButton.title = String(localized: "browser.import.next", defaultValue: "Next")
            primaryButton.keyEquivalent = "\r"

            let buttonSpacer = NSView(frame: .zero)

            let buttonRow = NSStackView(views: [buttonSpacer, backButton, cancelButton, primaryButton])
            buttonRow.orientation = .horizontal
            buttonRow.spacing = 8
            buttonRow.alignment = .centerY
            buttonRow.translatesAutoresizingMaskIntoConstraints = false
            buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            buttonSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let contentStack = NSStackView(views: [
                titleLabel,
                stepLabel,
                sourceContainer,
                sourceProfilesContainer,
                dataTypesContainer,
                validationLabel,
            ])
            contentStack.orientation = .vertical
            contentStack.spacing = 8
            contentStack.alignment = .leading
            contentStack.translatesAutoresizingMaskIntoConstraints = false

            sourceContainer.translatesAutoresizingMaskIntoConstraints = false
            sourceProfilesContainer.translatesAutoresizingMaskIntoConstraints = false
            dataTypesContainer.translatesAutoresizingMaskIntoConstraints = false

            guard let panelContent = panel.contentView else { return }
            panelContent.addSubview(contentStack)
            panelContent.addSubview(buttonRow)

            NSLayoutConstraint.activate([
                contentStack.topAnchor.constraint(equalTo: panelContent.topAnchor, constant: 16),
                contentStack.leadingAnchor.constraint(equalTo: panelContent.leadingAnchor, constant: 18),
                contentStack.trailingAnchor.constraint(equalTo: panelContent.trailingAnchor, constant: -18),

                buttonRow.topAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor, constant: 14),
                buttonRow.leadingAnchor.constraint(equalTo: panelContent.leadingAnchor, constant: 18),
                buttonRow.trailingAnchor.constraint(equalTo: panelContent.trailingAnchor, constant: -18),
                buttonRow.bottomAnchor.constraint(equalTo: panelContent.bottomAnchor, constant: -14),

                sourceContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
                sourceProfilesContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
                dataTypesContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
                validationLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            ])
        }

        private func setupSourceContainer() {
            for browser in browsers {
                sourcePopup.addItem(withTitle: browser.displayName)
            }
            sourcePopup.selectItem(at: 0)
            sourcePopup.target = self
            sourcePopup.action = #selector(handleSourceChanged)

            let sourceLabel = NSTextField(
                labelWithString: String(localized: "browser.import.source", defaultValue: "Source")
            )
            sourceLabel.alignment = .right
            sourceLabel.frame.size.width = 64

            sourcePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            sourcePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let sourceRow = NSStackView(views: [sourceLabel, sourcePopup])
            sourceRow.orientation = .horizontal
            sourceRow.spacing = 8
            sourceRow.alignment = .centerY
            sourceRow.distribution = .fill

            let detectedLabel = NSTextField(
                wrappingLabelWithString: installedBrowserDetector.summaryText(for: browsers)
            )
            detectedLabel.font = NSFont.systemFont(ofSize: 11)
            detectedLabel.textColor = .secondaryLabelColor
            detectedLabel.maximumNumberOfLines = 2
            detectedLabel.preferredMaxLayoutWidth = 500

            sourceContainer.orientation = .vertical
            sourceContainer.spacing = 8
            sourceContainer.alignment = .leading
            sourceContainer.addArrangedSubview(sourceRow)
            sourceContainer.addArrangedSubview(detectedLabel)
        }

        private func setupSourceProfilesContainer() {
            let sourceProfilesTitle = NSTextField(
                labelWithString: String(
                    localized: "browser.import.sourceProfiles",
                    defaultValue: "Source Profiles"
                )
            )
            sourceProfilesTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

            sourceProfilesList.orientation = .vertical
            sourceProfilesList.spacing = 6
            sourceProfilesList.alignment = .leading
            sourceProfilesList.translatesAutoresizingMaskIntoConstraints = false

            sourceProfilesEmptyLabel.font = NSFont.systemFont(ofSize: 12)
            sourceProfilesEmptyLabel.textColor = .secondaryLabelColor
            sourceProfilesEmptyLabel.maximumNumberOfLines = 0
            sourceProfilesEmptyLabel.preferredMaxLayoutWidth = 500

            sourceProfilesDocumentView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            sourceProfilesDocumentView.translatesAutoresizingMaskIntoConstraints = false
            sourceProfilesDocumentView.addSubview(sourceProfilesList)
            NSLayoutConstraint.activate([
                sourceProfilesList.topAnchor.constraint(equalTo: sourceProfilesDocumentView.topAnchor),
                sourceProfilesList.leadingAnchor.constraint(equalTo: sourceProfilesDocumentView.leadingAnchor),
                sourceProfilesList.trailingAnchor.constraint(equalTo: sourceProfilesDocumentView.trailingAnchor),
                sourceProfilesList.bottomAnchor.constraint(equalTo: sourceProfilesDocumentView.bottomAnchor),
                sourceProfilesList.widthAnchor.constraint(equalTo: sourceProfilesDocumentView.widthAnchor),
            ])

            sourceProfilesScrollView.drawsBackground = false
            sourceProfilesScrollView.borderType = .bezelBorder
            sourceProfilesScrollView.hasVerticalScroller = true
            sourceProfilesScrollView.documentView = sourceProfilesDocumentView
            sourceProfilesScrollView.translatesAutoresizingMaskIntoConstraints = false
            sourceProfilesScrollView.contentView.postsBoundsChangedNotifications = true
            sourceProfilesScrollHeightConstraint = sourceProfilesScrollView.heightAnchor.constraint(equalToConstant: 76)
            sourceProfilesScrollHeightConstraint?.isActive = true
            let sourceProfilesScrollWidthConstraint = sourceProfilesScrollView.widthAnchor.constraint(
                equalTo: sourceProfilesContainer.widthAnchor
            )

            sourceProfilesHelpLabel.font = NSFont.systemFont(ofSize: 11)
            sourceProfilesHelpLabel.textColor = .secondaryLabelColor
            sourceProfilesHelpLabel.maximumNumberOfLines = 2
            sourceProfilesHelpLabel.lineBreakMode = .byWordWrapping
            sourceProfilesHelpLabel.preferredMaxLayoutWidth = 500
            sourceProfilesHelpLabel.stringValue = String(
                localized: "browser.import.sourceProfiles.help",
                defaultValue: "Choose one or more source profiles. Step 3 lets you keep them separate or merge them into one cmux profile."
            )

            sourceProfilesContainer.orientation = .vertical
            sourceProfilesContainer.spacing = 8
            sourceProfilesContainer.alignment = .leading
            sourceProfilesContainer.addArrangedSubview(sourceProfilesTitle)
            sourceProfilesContainer.addArrangedSubview(sourceProfilesScrollView)
            sourceProfilesContainer.addArrangedSubview(sourceProfilesHelpLabel)
            sourceProfilesScrollWidthConstraint.isActive = true
            sourceProfilesContainer.setHuggingPriority(.defaultLow, for: .vertical)
            sourceProfilesContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        private func setupDataTypesContainer() {
            let initialScope = defaultScope ?? .cookiesAndHistory
            cookiesCheckbox.state = initialScope.includesCookies ? .on : .off
            historyCheckbox.state = initialScope.includesHistory ? .on : .off
            additionalDataCheckbox.state = initialScope == .everything ? .on : .off
            cookiesCheckbox.title = String(
                localized: "browser.import.cookies",
                defaultValue: "Cookies (site sign-ins)"
            )
            historyCheckbox.title = String(
                localized: "browser.import.history",
                defaultValue: "History (visited pages)"
            )
            additionalDataCheckbox.title = String(
                localized: "browser.import.additionalData",
                defaultValue: "Additional data (bookmarks, settings, extensions)"
            )
            cookiesCheckbox.target = self
            cookiesCheckbox.action = #selector(handleImportOptionChanged(_:))
            historyCheckbox.target = self
            historyCheckbox.action = #selector(handleImportOptionChanged(_:))
            additionalDataCheckbox.target = self
            additionalDataCheckbox.action = #selector(handleImportOptionChanged(_:))
            cookiesCheckbox.setAccessibilityIdentifier("BrowserImportCookiesCheckbox")
            historyCheckbox.setAccessibilityIdentifier("BrowserImportHistoryCheckbox")
            additionalDataCheckbox.setAccessibilityIdentifier("BrowserImportAdditionalDataCheckbox")
            separateProfilesRadio.title = String(
                localized: "browser.import.destinationMode.separate",
                defaultValue: "Keep profiles separate"
            )
            mergeProfilesRadio.title = String(
                localized: "browser.import.destinationMode.merge",
                defaultValue: "Merge all into one cmux profile"
            )
            separateProfilesRadio.target = self
            separateProfilesRadio.action = #selector(handleDestinationModeChanged(_:))
            mergeProfilesRadio.target = self
            mergeProfilesRadio.action = #selector(handleDestinationModeChanged(_:))

            destinationModeContainer.orientation = .vertical
            destinationModeContainer.spacing = 6
            destinationModeContainer.alignment = .leading
            destinationModeContainer.addArrangedSubview(separateProfilesRadio)
            destinationModeContainer.addArrangedSubview(mergeProfilesRadio)

            mergeDestinationPopup.target = self
            mergeDestinationPopup.action = #selector(handleMergeDestinationChanged(_:))
            mergeDestinationPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            mergeDestinationPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            separateDestinationRows.orientation = .vertical
            separateDestinationRows.spacing = 6
            separateDestinationRows.alignment = .leading

            mergeDestinationRow.orientation = .horizontal
            mergeDestinationRow.spacing = 6
            mergeDestinationRow.alignment = .centerY

            destinationHelpLabel.font = NSFont.systemFont(ofSize: 11)
            destinationHelpLabel.textColor = .secondaryLabelColor
            destinationHelpLabel.maximumNumberOfLines = 2
            destinationHelpLabel.preferredMaxLayoutWidth = 500

            domainField.placeholderString = String(
                localized: "browser.import.domain.placeholder",
                defaultValue: "Optional domains only (e.g. github.com, openai.com)"
            )
            domainField.stringValue = ""
            domainField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            domainField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let destinationTitleLabel = NSTextField(
                labelWithString: String(
                    localized: "browser.import.destination.cmux",
                    defaultValue: "cmux destination"
                )
            )
            destinationTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

            let domainLabel = NSTextField(
                labelWithString: String(localized: "browser.import.domain", defaultValue: "Limit to")
            )
            domainLabel.alignment = .right
            domainLabel.frame.size.width = 72

            let domainRow = NSStackView(views: [domainLabel, domainField])
            domainRow.orientation = .horizontal
            domainRow.spacing = 8
            domainRow.alignment = .centerY
            domainRow.distribution = .fill

            additionalDataNoteLabel.stringValue = String(
                localized: "browser.import.additionalData.note",
                defaultValue: "Bookmarks, settings, and extensions import are not available yet."
            )
            additionalDataNoteLabel.font = NSFont.systemFont(ofSize: 11)
            additionalDataNoteLabel.textColor = .secondaryLabelColor
            additionalDataNoteLabel.maximumNumberOfLines = 2
            additionalDataNoteLabel.preferredMaxLayoutWidth = 500
            additionalDataNoteLabel.isHidden = true

            dataTypesContainer.orientation = .vertical
            dataTypesContainer.spacing = 6
            dataTypesContainer.alignment = .leading
            dataTypesContainer.addArrangedSubview(destinationTitleLabel)
            dataTypesContainer.addArrangedSubview(destinationModeContainer)
            dataTypesContainer.addArrangedSubview(separateDestinationRows)
            dataTypesContainer.addArrangedSubview(mergeDestinationRow)
            dataTypesContainer.addArrangedSubview(destinationHelpLabel)
            dataTypesContainer.addArrangedSubview(cookiesCheckbox)
            dataTypesContainer.addArrangedSubview(historyCheckbox)
            dataTypesContainer.addArrangedSubview(additionalDataCheckbox)
            dataTypesContainer.addArrangedSubview(additionalDataNoteLabel)
            dataTypesContainer.addArrangedSubview(domainRow)
        }

        private func configureInitialState() {
            step = .source
            refreshSourceProfilesList()
            updateAdditionalDataNoteVisibility()
            updateStepUI()
        }

        private func updateStepUI() {
            switch step {
            case .source:
                stepLabel.stringValue = String(
                    localized: "browser.import.step.source",
                    defaultValue: "Step 1 of 3"
                )
                sourceContainer.isHidden = false
                sourceProfilesContainer.isHidden = true
                dataTypesContainer.isHidden = true
                backButton.isHidden = true
                primaryButton.isEnabled = true
                primaryButton.title = String(localized: "browser.import.next", defaultValue: "Next")
            case .sourceProfiles:
                stepLabel.stringValue = String(
                    localized: "browser.import.step.sourceProfiles",
                    defaultValue: "Step 2 of 3"
                )
                sourceContainer.isHidden = true
                sourceProfilesContainer.isHidden = false
                dataTypesContainer.isHidden = true
                backButton.isHidden = false
                primaryButton.isEnabled = !selectedBrowser().profiles.isEmpty
                primaryButton.title = String(localized: "browser.import.next", defaultValue: "Next")
            case .dataTypes:
                rebuildStep3DestinationUI()
                stepLabel.stringValue = String(
                    localized: "browser.import.step.dataTypes",
                    defaultValue: "Step 3 of 3"
                )
                sourceContainer.isHidden = true
                sourceProfilesContainer.isHidden = true
                dataTypesContainer.isHidden = false
                backButton.isHidden = false
                primaryButton.isEnabled = true
                primaryButton.title = String(
                    localized: "browser.import.start",
                    defaultValue: "Start Import"
                )
            }
            updatePanelSize()
        }

        private func selectedBrowser() -> InstalledBrowserCandidate {
            let selectedIndex = max(0, min(sourcePopup.indexOfSelectedItem, browsers.count - 1))
            return browsers[selectedIndex]
        }

        private func refreshSourceProfilesList() {
            let browser = selectedBrowser()
            let selectedIDs = storedSelectedSourceProfileIDs(for: browser)

            sourceProfileCheckboxes.removeAll()
            for arrangedSubview in sourceProfilesList.arrangedSubviews {
                sourceProfilesList.removeArrangedSubview(arrangedSubview)
                arrangedSubview.removeFromSuperview()
            }

            if browser.profiles.isEmpty {
                sourceProfilesEmptyLabel.stringValue = String(
                    format: String(
                        localized: "browser.import.sourceProfiles.empty",
                        defaultValue: "No source profiles detected for %@."
                    ),
                    browser.displayName
                )
                sourceProfilesList.addArrangedSubview(sourceProfilesEmptyLabel)
                updateSourceProfilesPresentation(for: browser)
                return
            }

            for profile in browser.profiles {
                let checkbox = NSButton(
                    checkboxWithTitle: profile.displayName,
                    target: self,
                    action: #selector(handleSourceProfileToggled(_:))
                )
                checkbox.identifier = NSUserInterfaceItemIdentifier(profile.id)
                checkbox.state = selectedIDs.contains(profile.id) ? .on : .off
                checkbox.lineBreakMode = .byTruncatingTail
                sourceProfilesList.addArrangedSubview(checkbox)
                sourceProfileCheckboxes.append(checkbox)
            }

            updateSourceProfilesPresentation(for: browser)
        }

        private func storedSelectedSourceProfileIDs(for browser: InstalledBrowserCandidate) -> Set<String> {
            if let existing = selectedSourceProfileIDsByBrowserID[browser.id] {
                return existing
            }
            let defaultSelection = defaultSelectedSourceProfileIDs(for: browser)
            selectedSourceProfileIDsByBrowserID[browser.id] = defaultSelection
            return defaultSelection
        }

        private func defaultSelectedSourceProfileIDs(for browser: InstalledBrowserCandidate) -> Set<String> {
            if let defaultProfile = browser.profiles.first(where: \.isDefault) {
                return [defaultProfile.id]
            }
            if let firstProfile = browser.profiles.first {
                return [firstProfile.id]
            }
            return []
        }

        private func selectedSourceProfiles() -> [InstalledBrowserProfile] {
            let browser = selectedBrowser()
            let selectedIDs = storedSelectedSourceProfileIDs(for: browser)
            return browser.profiles.filter { selectedIDs.contains($0.id) }
        }

        private func resetStep3State() {
            let selectedProfiles = selectedSourceProfiles()
            let defaultPlan = BrowserImportPlanResolver().defaultPlan(
                selectedSourceProfiles: selectedProfiles,
                destinationProfiles: destinationProfiles,
                preferredSingleDestinationProfileID: initialDestinationProfileID
            )
            destinationMode = defaultPlan.mode
            separateExecutionEntries = BrowserImportPlanResolver().separateProfilesPlan(
                selectedSourceProfiles: selectedProfiles,
                destinationProfiles: destinationProfiles
            ).entries
            if let initialDestination = defaultPlan.entries.first.flatMap(destinationProfileID(for:)) {
                mergeDestinationProfileID = initialDestination
            } else {
                mergeDestinationProfileID = initialDestinationProfileID
            }
            rebuildStep3DestinationUI()
        }

        private func currentExecutionPlan() -> BrowserImportExecutionPlan {
            let selectedProfiles = selectedSourceProfiles()
            guard !selectedProfiles.isEmpty else {
                return BrowserImportExecutionPlan(mode: .singleDestination, entries: [])
            }

            guard selectedProfiles.count > 1 else {
                return BrowserImportExecutionPlan(
                    mode: .singleDestination,
                    entries: [
                        BrowserImportExecutionEntry(
                            sourceProfiles: selectedProfiles,
                            destination: .existing(resolvedMergeDestinationProfileID())
                        )
                    ]
                )
            }

            switch destinationMode {
            case .separateProfiles:
                let entriesBySourceID = Dictionary(
                    uniqueKeysWithValues: separateExecutionEntries.compactMap { entry in
                        entry.sourceProfiles.first.map { ($0.id, entry.destination) }
                    }
                )
                let entries = selectedProfiles.map { profile in
                    BrowserImportExecutionEntry(
                        sourceProfiles: [profile],
                        destination: entriesBySourceID[profile.id] ?? defaultSeparateDestinationRequest(for: profile)
                    )
                }
                return BrowserImportExecutionPlan(mode: .separateProfiles, entries: entries)
            case .singleDestination, .mergeIntoOne:
                return BrowserImportExecutionPlan(
                    mode: .mergeIntoOne,
                    entries: [
                        BrowserImportExecutionEntry(
                            sourceProfiles: selectedProfiles,
                            destination: .existing(resolvedMergeDestinationProfileID())
                        )
                    ]
                )
            }
        }

        private func rebuildStep3DestinationUI() {
            let plan = currentExecutionPlan()
            let presentation = BrowserImportStep3Presentation(plan: plan)
            destinationModeContainer.isHidden = !presentation.showsModeSelector
            separateDestinationRows.isHidden = !presentation.showsSeparateRows
            mergeDestinationRow.isHidden = !presentation.showsSingleDestinationPicker

            if presentation.showsModeSelector {
                separateProfilesRadio.state = destinationMode == .separateProfiles ? .on : .off
                mergeProfilesRadio.state = destinationMode == .mergeIntoOne ? .on : .off
            } else {
                separateProfilesRadio.state = .off
                mergeProfilesRadio.state = .off
            }

            rebuildSeparateDestinationRows(with: plan)
            rebuildMergeDestinationRow()

            if presentation.showsSeparateRows {
                destinationHelpLabel.stringValue = String(
                    localized: "browser.import.destinationProfile.separateHelp",
                    defaultValue: "Missing cmux profiles are created when import starts."
                )
                destinationHelpLabel.isHidden = false
            } else if plan.entries.count > 1 {
                destinationHelpLabel.stringValue = String(
                    localized: "browser.import.destinationProfile.mergeHelp",
                    defaultValue: "All selected source profiles will be merged into the chosen cmux browser profile."
                )
                destinationHelpLabel.isHidden = false
            } else {
                destinationHelpLabel.stringValue = ""
                destinationHelpLabel.isHidden = true
            }
        }

        private func rebuildSeparateDestinationRows(with plan: BrowserImportExecutionPlan) {
            separateDestinationOptionsByEntryIndex.removeAll()
            for arrangedSubview in separateDestinationRows.arrangedSubviews {
                separateDestinationRows.removeArrangedSubview(arrangedSubview)
                arrangedSubview.removeFromSuperview()
            }

            guard plan.mode == .separateProfiles else { return }

            for (index, entry) in plan.entries.enumerated() {
                guard let sourceProfile = entry.sourceProfiles.first else { continue }
                let sourceLabel = NSTextField(labelWithString: sourceProfile.displayName)
                sourceLabel.alignment = .right
                sourceLabel.frame.size.width = 110

                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.target = self
                popup.action = #selector(handleSeparateDestinationChanged(_:))
                popup.tag = index
                popup.setAccessibilityIdentifier(
                    "BrowserImportDestinationPopup-\(accessibilitySlug(for: sourceProfile, index: index))"
                )

                let options = destinationOptions(for: entry, sourceProfile: sourceProfile)
                separateDestinationOptionsByEntryIndex[index] = options
                for option in options {
                    popup.addItem(withTitle: title(for: option))
                }
                if let selectedIndex = options.firstIndex(of: entry.destination) {
                    popup.selectItem(at: selectedIndex)
                } else {
                    popup.selectItem(at: 0)
                }
                popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
                popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

                let row = NSStackView(views: [sourceLabel, popup])
                row.orientation = .horizontal
                row.spacing = 6
                row.alignment = .centerY
                row.distribution = .fill
                separateDestinationRows.addArrangedSubview(row)
            }
        }

        private func rebuildMergeDestinationRow() {
            for arrangedSubview in mergeDestinationRow.arrangedSubviews {
                mergeDestinationRow.removeArrangedSubview(arrangedSubview)
                arrangedSubview.removeFromSuperview()
            }

            mergeDestinationPopup.removeAllItems()
            for profile in destinationProfiles {
                mergeDestinationPopup.addItem(withTitle: profile.displayName)
            }
            if let selectedIndex = destinationProfiles.firstIndex(where: { $0.id == resolvedMergeDestinationProfileID() }) {
                mergeDestinationPopup.selectItem(at: selectedIndex)
            } else {
                mergeDestinationPopup.selectItem(at: 0)
                if let firstProfile = destinationProfiles.first {
                    mergeDestinationProfileID = firstProfile.id
                }
            }
            mergeDestinationPopup.setAccessibilityIdentifier("BrowserImportDestinationPopup-merge")

            let destinationLabel = NSTextField(
                labelWithString: String(
                    localized: "browser.import.destinationProfile",
                    defaultValue: "Import into"
                )
            )
            destinationLabel.alignment = .right
            destinationLabel.frame.size.width = 110

            mergeDestinationRow.addArrangedSubview(destinationLabel)
            mergeDestinationRow.addArrangedSubview(mergeDestinationPopup)
        }

        private func destinationOptions(
            for entry: BrowserImportExecutionEntry,
            sourceProfile: InstalledBrowserProfile
        ) -> [BrowserImportDestinationRequest] {
            var options = destinationProfiles.map { BrowserImportDestinationRequest.existing($0.id) }
            let createName: String
            switch entry.destination {
            case .createNamed(let name):
                createName = name
            case .existing:
                createName = sourceProfile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !createName.isEmpty,
               !destinationProfiles.contains(where: {
                   $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                       .localizedCaseInsensitiveCompare(createName) == .orderedSame
               }) {
                options.append(.createNamed(createName))
            }
            return options
        }

        private func title(for request: BrowserImportDestinationRequest) -> String {
            switch request {
            case .existing(let id):
                return destinationProfiles.first(where: { $0.id == id })?.displayName
                    ?? BrowserProfileStore.shared.displayName(for: id)
            case .createNamed(let name):
                return String(
                    format: String(
                        localized: "browser.import.destinationProfile.create",
                        defaultValue: "Create \"%@\""
                    ),
                    name
                )
            }
        }

        private func destinationProfileID(for entry: BrowserImportExecutionEntry) -> UUID? {
            guard case .existing(let id) = entry.destination else { return nil }
            return id
        }

        private func resolvedMergeDestinationProfileID() -> UUID {
            if destinationProfiles.contains(where: { $0.id == mergeDestinationProfileID }) {
                return mergeDestinationProfileID
            }
            return initialDestinationProfileID
        }

        private func defaultSeparateDestinationRequest(
            for profile: InstalledBrowserProfile
        ) -> BrowserImportDestinationRequest {
            BrowserImportPlanResolver().separateProfilesPlan(
                selectedSourceProfiles: [profile],
                destinationProfiles: destinationProfiles
            ).entries.first?.destination ?? .createNamed(profile.displayName)
        }

        private func accessibilitySlug(for profile: InstalledBrowserProfile, index: Int) -> String {
            let base = profile.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return base.isEmpty ? "profile-\(index)" : base
        }

        private func updateSourceProfilesPresentation(for browser: InstalledBrowserCandidate) {
            let presentation = BrowserImportSourceProfilesPresentation(profileCount: browser.profiles.count)
            sourceProfilesScrollHeightConstraint?.constant = presentation.scrollHeight
            sourceProfilesHelpLabel.isHidden = !presentation.showsHelpText
        }

        private func updateAdditionalDataNoteVisibility() {
            additionalDataNoteLabel.isHidden = additionalDataCheckbox.state != .on
        }

        private func updatePanelSize() {
            let contentSize = preferredContentSize()
            let targetFrame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))

            guard panel.frame.size != targetFrame.size else { return }
            if !panel.isVisible {
                panel.setContentSize(contentSize)
                return
            }

            var frame = panel.frame
            frame.origin.x -= (targetFrame.width - frame.width) / 2
            frame.origin.y -= (targetFrame.height - frame.height) / 2
            frame.size = targetFrame.size
            panel.setFrame(frame, display: true)
        }

        private func preferredContentSize() -> NSSize {
            switch step {
            case .source:
                return NSSize(width: 560, height: 292)
            case .sourceProfiles:
                let presentation = BrowserImportSourceProfilesPresentation(profileCount: selectedBrowser().profiles.count)
                let helpHeight: CGFloat = presentation.showsHelpText ? 24 : 0
                let height = 214 + presentation.scrollHeight + helpHeight
                return NSSize(width: 560, height: min(max(height, 292), 360))
            case .dataTypes:
                var height: CGFloat = currentExecutionPlan().mode == .separateProfiles ? 412 : 374
                if additionalDataCheckbox.state == .on {
                    height += 24
                }
                return NSSize(width: 560, height: height)
            }
        }

        private func finishModal(with response: NSApplication.ModalResponse) {
            guard !didFinishModal else { return }
            didFinishModal = true

            if NSApp.modalWindow == panel {
                NSApp.stopModal(withCode: response)
            }
            panel.orderOut(nil)
        }
    }

    private func showProgressWindow(title: String, message: String) -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 122),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 122))

        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 50, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        content.addSubview(spinner)

        let titleLabel = NSTextField(labelWithString: message)
        titleLabel.frame = NSRect(x: 52, y: 56, width: 340, height: 20)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        content.addSubview(titleLabel)

        let subtitleLabel = NSTextField(
            labelWithString: String(
                localized: "browser.import.progress.subtitle",
                defaultValue: "This can take a few seconds for large profiles."
            )
        )
        subtitleLabel.frame = NSRect(x: 52, y: 34, width: 340, height: 16)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        content.addSubview(subtitleLabel)

        window.contentView = content

        if let keyWindow = NSApp.keyWindow {
            keyWindow.beginSheet(window, completionHandler: nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }

        return window
    }

    private func hideProgressWindow(_ window: NSWindow) {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    private func presentOutcome(_ outcome: BrowserImportOutcome) {
        let lines = outcome.formattedLines
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "browser.import.complete.title",
            defaultValue: "Browser data import complete"
        )
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }
}

extension BrowserPanel {
    /// Debug-log sink handed to `BrowserOmnibarPageFocusRepository`.
    ///
    /// In release builds this is `nil`, so the repository emits no logging and
    /// the former `#if DEBUG`-guarded `cmuxDebugLog` calls stay compiled out.
    static var omnibarPageFocusLogSink: (@MainActor @Sendable (String) -> Void)? {
#if DEBUG
        return { message in cmuxDebugLog(message) }
#else
        return nil
#endif
    }
}

/// Bridges `BrowserOmnibarPageFocusRepository` to a panel's live `WKWebView`.
///
/// Holds the panel weakly so the panel (which owns the repository, which owns
/// this adapter) does not form a retain cycle. Always reads `panel.webView` at
/// call time because the panel reassigns its web view across navigations and
/// profile switches.
@MainActor
private final class BrowserOmnibarPageFocusAdapter: BrowserOmnibarScriptEvaluating {
    private weak var panel: BrowserPanel?

    init(panel: BrowserPanel) {
        self.panel = panel
    }

    func evaluateOmnibarPageFocusScript(
        _ script: String,
        completion: @escaping @MainActor (Any?, (any Error)?) -> Void
    ) {
        guard let panel else {
            completion(nil, nil)
            return
        }
        panel.webView.evaluateJavaScript(script) { result, error in
            MainActor.assumeIsolated {
                completion(result, error)
            }
        }
    }
}
