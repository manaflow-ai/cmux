import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif

enum BrowserAddressBarFocusSelectionIntent: Equatable {
    case preserveFieldEditorSelection
    case selectAll

    var shouldSelectAll: Bool {
        self == .selectAll
    }
}

func dedupedCanonicalURLs(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    var result: [URL] = []
    for url in urls {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        if seen.insert(canonical).inserted {
            result.append(url)
        }
    }
    return result
}

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
        self.modifierFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
            .rawValue
    }
}

struct BrowserProxyEndpoint: Equatable {
    let host: String
    let port: Int
}

struct BrowserRemoteWorkspaceStatus: Equatable {
    let target: String
    let connectionState: WorkspaceRemoteConnectionState
    let heartbeatCount: Int
    let lastHeartbeatAt: Date?
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

/// BrowserPanel provides a WKWebView-based browser panel.
/// Each browser panel can recover from WebContent crashes by replacing its web view.
enum BrowserInsecureHTTPNavigationIntent {
    case currentTab
    case newTab
}

nonisolated enum BrowserWebViewLifecycleState: String {
    case newTab = "new_tab"
    case deferredURL = "deferred_url"
    case liveVisible = "live_visible"
    case liveHidden = "live_hidden"
    case discarded
    case closing
}

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
final class BrowserPanel: Panel, ObservableObject {
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
    private var addressBarFocusRestoreGeneration: UInt64 = 0
    private let blankURLString = "about:blank"
    private static let addressBarFocusCaptureScript = """
    (() => {
      try {
        const syncState = (state) => {
          window.__cmuxAddressBarFocusState = state;
          try {
            if (window.top && window.top !== window) {
              window.top.postMessage({ cmuxAddressBarFocusState: state }, "*");
            } else if (window.top) {
              window.top.__cmuxAddressBarFocusState = state;
            }
          } catch (_) {}
        };

        const active = document.activeElement;
        if (!active) {
          syncState(null);
          return "cleared:none";
        }

        const tag = (active.tagName || "").toLowerCase();
        const type = (active.type || "").toLowerCase();
        const isEditable =
          !!active.isContentEditable ||
          tag === "textarea" ||
          (tag === "input" && type !== "hidden");
        if (!isEditable) {
          syncState(null);
          return "cleared:noneditable";
        }

        let id = active.getAttribute("data-cmux-addressbar-focus-id");
        if (!id) {
          id = "cmux-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8);
          active.setAttribute("data-cmux-addressbar-focus-id", id);
        }

        const state = { id, selectionStart: null, selectionEnd: null };
        if (typeof active.selectionStart === "number" && typeof active.selectionEnd === "number") {
          state.selectionStart = active.selectionStart;
          state.selectionEnd = active.selectionEnd;
        }
        syncState(state);
        return "captured:" + id;
      } catch (_) {
        return "error";
      }
    })();
    """
    private static let addressBarFocusTrackingBootstrapScript = """
    (() => {
      try {
        if (window.__cmuxAddressBarFocusTrackerInstalled) return true;
        window.__cmuxAddressBarFocusTrackerInstalled = true;

        const syncState = (state) => {
          window.__cmuxAddressBarFocusState = state;
          try {
            if (window.top && window.top !== window) {
              window.top.postMessage({ cmuxAddressBarFocusState: state }, "*");
            } else if (window.top) {
              window.top.__cmuxAddressBarFocusState = state;
            }
          } catch (_) {}
        };

        if (window.top === window && !window.__cmuxAddressBarFocusMessageBridgeInstalled) {
          window.__cmuxAddressBarFocusMessageBridgeInstalled = true;
          window.addEventListener("message", (ev) => {
            try {
              const data = ev ? ev.data : null;
              if (!data || !Object.prototype.hasOwnProperty.call(data, "cmuxAddressBarFocusState")) return;
              window.__cmuxAddressBarFocusState = data.cmuxAddressBarFocusState || null;
            } catch (_) {}
          }, true);
        }

        const isEditable = (el) => {
          if (!el) return false;
          const tag = (el.tagName || "").toLowerCase();
          const type = (el.type || "").toLowerCase();
          return !!el.isContentEditable || tag === "textarea" || (tag === "input" && type !== "hidden");
        };

        const ensureFocusId = (el) => {
          let id = el.getAttribute("data-cmux-addressbar-focus-id");
          if (!id) {
            id = "cmux-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8);
            el.setAttribute("data-cmux-addressbar-focus-id", id);
          }
          return id;
        };

        const snapshot = (el) => {
          if (!isEditable(el)) {
            syncState(null);
            return;
          }
          const state = {
            id: ensureFocusId(el),
            selectionStart: null,
            selectionEnd: null
          };
          if (typeof el.selectionStart === "number" && typeof el.selectionEnd === "number") {
            state.selectionStart = el.selectionStart;
            state.selectionEnd = el.selectionEnd;
          }
          syncState(state);
        };

        document.addEventListener("focusin", (ev) => {
          snapshot(ev && ev.target ? ev.target : document.activeElement);
        }, true);
        document.addEventListener("selectionchange", () => {
          snapshot(document.activeElement);
        }, true);
        document.addEventListener("input", () => {
          snapshot(document.activeElement);
        }, true);
        document.addEventListener("mousedown", (ev) => {
          const target = ev && ev.target ? ev.target : null;
          if (!isEditable(target)) {
            syncState(null);
          }
        }, true);
        window.addEventListener("beforeunload", () => {
          syncState(null);
        }, true);

        snapshot(document.activeElement);
        return true;
      } catch (_) {
        return false;
      }
    })();
    """
    private static let addressBarFocusRestoreScript = """
    (() => {
      try {
        const readState = () => {
          let state = window.__cmuxAddressBarFocusState;
          try {
            if ((!state || typeof state.id !== "string" || !state.id) &&
                window.top && window.top.__cmuxAddressBarFocusState) {
              state = window.top.__cmuxAddressBarFocusState;
            }
          } catch (_) {}
          return state;
        };

        const clearState = () => {
          window.__cmuxAddressBarFocusState = null;
          try {
            if (window.top && window.top !== window) {
              window.top.postMessage({ cmuxAddressBarFocusState: null }, "*");
            } else if (window.top) {
              window.top.__cmuxAddressBarFocusState = null;
            }
          } catch (_) {}
        };

        const state = readState();
        if (!state || typeof state.id !== "string" || !state.id) {
          return "no_state";
        }

        const selector = '[data-cmux-addressbar-focus-id="' + state.id + '"]';
        const findTarget = (doc) => {
          if (!doc) return null;
          const direct = doc.querySelector(selector);
          if (direct && direct.isConnected) return direct;
          const frames = doc.querySelectorAll("iframe,frame");
          for (let i = 0; i < frames.length; i += 1) {
            const frame = frames[i];
            try {
              const childDoc = frame.contentDocument;
              if (!childDoc) continue;
              const nested = findTarget(childDoc);
              if (nested) return nested;
            } catch (_) {}
          }
          return null;
        };

        const target = findTarget(document);
        if (!target) {
          clearState();
          return "missing_target";
        }

        try {
          target.focus({ preventScroll: true });
        } catch (_) {
          try { target.focus(); } catch (_) {}
        }

        let focused = false;
        try {
          focused =
            target === target.ownerDocument.activeElement ||
            (typeof target.matches === "function" && target.matches(":focus"));
        } catch (_) {}
        if (!focused) {
          return "not_focused";
        }

        if (
          typeof state.selectionStart === "number" &&
          typeof state.selectionEnd === "number" &&
          typeof target.setSelectionRange === "function"
        ) {
          try {
            target.setSelectionRange(state.selectionStart, state.selectionEnd);
          } catch (_) {}
        }
        clearState();
        return "restored";
      } catch (_) {
        return "error";
      }
    })();
    """

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

    /// True when the browser is showing the internal empty new-tab page.
    var isShowingNewTabPage: Bool {
        !shouldRenderWebView && preferredURLStringForOmnibar() == nil
    }

    var isShowingBlankBrowserPage: Bool {
        Self.isBlankBrowserPage(
            liveURL: Self.remoteProxyDisplayURL(for: webView.url) ?? webView.url,
            currentURL: currentURL,
            pendingNavigationURL: Self.remoteProxyDisplayURL(for: navigationDelegate?.lastAttemptedURL)
                ?? navigationDelegate?.lastAttemptedURL,
            isMainFrameProvisionalNavigationActive: isMainFrameProvisionalNavigationActive
        )
    }

    /// Published page title
    @Published private(set) var pageTitle: String = ""

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

    private var nativeCanGoBack: Bool = false
    private var nativeCanGoForward: Bool = false
    private var usesRestoredSessionHistory: Bool = false
    private var restoredBackHistoryStack: [URL] = []
    private var restoredForwardHistoryStack: [URL] = []
    private var restoredHistoryCurrentURL: URL?
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

    /// Incremented whenever async browser find focus ownership changes.
    @Published private(set) var searchFocusRequestGeneration: UInt64 = 0
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
                        self.executeFindSearch(needle)
                    }
            } else if let oldValue {
                lastSearchNeedle = oldValue.needle
                searchNeedleCancellable = nil
                if preferredFocusIntent == .findField { preferredFocusIntent = .webView }
                invalidateSearchFocusRequests(reason: "searchStateCleared")
#if DEBUG
                cmuxDebugLog("browser.find.state.cleared panel=\(id.uuidString.prefix(5))")
#endif
                executeFindClear()
            }
        }
    }
    @Published private(set) var isElementFullscreenActive: Bool = false
    private var searchNeedleCancellable: AnyCancellable?
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
    private var webViewObservers: [NSKeyValueObservation] = []
    private var activeDownloadCount: Int = 0

    // Avoid flickering the loading indicator for very fast navigations.
    private let minLoadingIndicatorDuration: TimeInterval = 0.35
    private var loadingStartedAt: Date?
    private var loadingEndWorkItem: DispatchWorkItem?
    private var loadingGeneration: Int = 0

    private var faviconTask: Task<Void, Never>?
    private var faviconRefreshGeneration: Int = 0
    private var lastFaviconURLString: String?
    private let minPageZoom: CGFloat = 0.25
    private let maxPageZoom: CGFloat = 5.0
    private let pageZoomStep: CGFloat = 0.1
    private var insecureHTTPBypassHostOnce: String?
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
    /// Document ids of the frames currently reporting playing media. The pane is
    /// kept alive while this is non-empty.
    private var playingMediaFrameIDs: Set<String> = []
    var mediaPlaybackMessageHandler: BrowserMediaPlaybackMessageHandler?

    /// Folds a per-frame playback report into ``isPlayingMedia``. Lives here so
    /// the `private(set)` setter stays confined to this file.
    func applyMediaPlaybackReport(frameID: String, isPlaying: Bool) {
        if isPlaying {
            playingMediaFrameIDs.insert(frameID)
        } else {
            playingMediaFrameIDs.remove(frameID)
        }
        isPlayingMedia = !playingMediaFrameIDs.isEmpty
    }

    /// Clears all tracked playing frames (new webview bind or main-frame
    /// navigation, where the prior frame hooks are gone).
    func resetMediaPlaybackTracking() {
        playingMediaFrameIDs.removeAll()
        isPlayingMedia = false
    }
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
    private var usesRemoteWorkspaceProxy: Bool
    private struct PendingRemoteNavigation {
        let request: URLRequest
        let recordTypedNavigation: Bool
        let preserveRestoredSessionHistory: Bool
    }
    private var pendingRemoteNavigation: PendingRemoteNavigation?
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
    private var developerToolsLastAttachedHostAt: Date?
    private var developerToolsLastKnownVisibleAt: Date?
    private var detachedDeveloperToolsWindowCloseObserver: NSObjectProtocol?
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

    private func scheduleHiddenWebViewDiscardIfNeeded(reason: String) {
        hiddenWebViewDiscardManager.scheduleIfNeeded(reason: reason)
    }

    private func cancelHiddenWebViewDiscard() {
        hiddenWebViewDiscardManager.cancel()
    }

    private func reevaluateHiddenWebViewDiscardScheduling(reason: String) {
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
        let restoreURL = Self.remoteProxyDisplayURL(for: oldWebView.url) ?? currentURL
        let history = sessionNavigationHistorySnapshot()
        let historyCurrentURL = preferredURLStringForOmnibar() ?? restoreURL?.absoluteString
        let desiredZoom = max(minPageZoom, min(maxPageZoom, oldWebView.pageZoom))

        clearBrowserFocusMode(reason: "webViewDiscard")
        invalidateSearchFocusRequests(reason: "webViewDiscard")
        searchState = nil
        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        loadingGeneration &+= 1
        cancelPendingInteractiveBrowserPrompts(reason: "discardHiddenWebView")

        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        closeBackgroundPreloadHost(reason: "discardHiddenWebView")
        BrowserWindowPortalRegistry.detach(webView: oldWebView)
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
        applyRemoteProxyConfigurationIfAvailable()
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
    func restoreDiscardedWebViewIfNeeded(reason: String) -> Bool {
        return hiddenWebViewDiscardManager.restoreIfNeeded(reason: reason) {
            shouldRenderWebView = true
            guard let restoreURL = restoredHistoryCurrentURL ?? currentURL else {
                refreshNavigationAvailability()
                return
            }
            navigateWithoutInsecureHTTPPrompt(
                to: restoreURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true
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

    private static func makeWebView(
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
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
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

        // Enable developer extras (DevTools)
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.preferences.isElementFullscreenEnabled = true

        // Enable JavaScript
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserFileSystemAccessBridge.scriptSource,
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
        // Track the last editable focused element continuously so omnibar exit can
        // restore page input focus even if capture runs after first-responder handoff.
        // Main frame only — same CAPTCHA interference concern as telemetry hooks.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.addressBarFocusTrackingBootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        // Keep a native cache of whether the focused page element can currently accept
        // plain-text paste so Cmd+Shift+V is only consumed when the browser can use it.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: CmuxWebView.pasteAsPlainTextFocusTrackingBootstrapScriptSource,
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
        webView.onContextMenuOpenLinkInNewTab = { [weak self] url in
            self?.openLinkInNewTab(url: url)
        }
        configureMoveTabToNewWorkspaceContextMenu(for: webView); configureNavigationDelegateCallbacks()
        webView.navigationDelegate = navigationDelegate
        webView.uiDelegate = uiDelegate
        setupObservers(for: webView)
        setupReactGrabMessageHandler(for: webView)
        setupMediaPlaybackMessageHandler(for: webView)
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
                self.realignRestoredSessionHistoryToLiveCurrentIfPossible()
                boundHistoryStore.recordVisit(url: webView.url, title: webView.title)
                self.refreshFavicon(from: webView)
                // Keep find-in-page open through load completion and refresh matches for the new DOM.
                self.restoreFindStateAfterNavigation(replaySearch: true)
            }
        }
        navigationDelegate.didFailNavigation = { [weak self] failedWebView, failedURL in
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(failedWebView, instanceID: boundWebViewInstanceID) else { return }
                self.isMainFrameProvisionalNavigationActive = false
                if let url = URL(string: failedURL) {
                    self.currentURL = Self.remoteProxyDisplayURL(for: url) ?? url
                }
                // Clear stale title/favicon from the previous page so the tab
                // shows the failed URL instead of the old page's branding.
                self.pageTitle = failedURL.isEmpty ? "" : failedURL
                self.faviconPNGData = nil
                self.lastFaviconURLString = nil
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
        currentURL = Self.remoteProxyDisplayURL(for: webView.url)
        navigationDelegate?.lastAttemptedURL = nil
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
            BrowserSearchSettings.searchEngineKey: BrowserSearchSettings.defaultSearchEngine.rawValue,
            BrowserSearchSettings.customSearchEngineNameKey: BrowserSearchSettings.defaultCustomSearchEngineName,
            BrowserSearchSettings.customSearchEngineURLTemplateKey: BrowserSearchSettings.defaultCustomSearchEngineURLTemplate,
            BrowserSearchSettings.searchSuggestionsEnabledKey: BrowserSearchSettings.defaultSearchSuggestionsEnabled,
            BrowserToolbarAccessorySpacingDebugSettings.key: BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing,
            BrowserProfilePopoverDebugSettings.horizontalPaddingKey: BrowserProfilePopoverDebugSettings.defaultHorizontalPadding,
            BrowserProfilePopoverDebugSettings.verticalPaddingKey: BrowserProfilePopoverDebugSettings.defaultVerticalPadding,
            BrowserThemeSettings.modeKey: BrowserThemeSettings.defaultMode.rawValue,
        ])

        let resolvedThemeMode = BrowserThemeSettings.mode(defaults: defaults)
        let currentThemeRaw = defaults.string(forKey: BrowserThemeSettings.modeKey)
            ?? BrowserThemeSettings.defaultMode.rawValue
        if currentThemeRaw != resolvedThemeMode.rawValue {
            defaults.set(resolvedThemeMode.rawValue, forKey: BrowserThemeSettings.modeKey)
        }

        let resolvedHintVariant = BrowserImportHintSettings.variant(defaults: defaults)
        let currentHintRaw = defaults.string(forKey: BrowserImportHintSettings.variantKey)
            ?? BrowserImportHintSettings.defaultVariant.rawValue
        if currentHintRaw != resolvedHintVariant.rawValue {
            defaults.set(resolvedHintVariant.rawValue, forKey: BrowserImportHintSettings.variantKey)
        }

        let resolvedToolbarSpacing = BrowserToolbarAccessorySpacingDebugSettings.current(defaults: defaults)
        let currentToolbarSpacing = (defaults.object(forKey: BrowserToolbarAccessorySpacingDebugSettings.key) as? Int)
            ?? BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
        if currentToolbarSpacing != resolvedToolbarSpacing {
            defaults.set(resolvedToolbarSpacing, forKey: BrowserToolbarAccessorySpacingDebugSettings.key)
        }

        let resolvedHorizontalPadding = BrowserProfilePopoverDebugSettings.currentHorizontalPadding(defaults: defaults)
        let currentHorizontalPadding = (defaults.object(forKey: BrowserProfilePopoverDebugSettings.horizontalPaddingKey) as? NSNumber)?.doubleValue
            ?? BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
        if currentHorizontalPadding != resolvedHorizontalPadding {
            defaults.set(resolvedHorizontalPadding, forKey: BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
        }

        let resolvedVerticalPadding = BrowserProfilePopoverDebugSettings.currentVerticalPadding(defaults: defaults)
        let currentVerticalPadding = (defaults.object(forKey: BrowserProfilePopoverDebugSettings.verticalPaddingKey) as? NSNumber)?.doubleValue
            ?? BrowserProfilePopoverDebugSettings.defaultVerticalPadding
        if currentVerticalPadding != resolvedVerticalPadding {
            defaults.set(resolvedVerticalPadding, forKey: BrowserProfilePopoverDebugSettings.verticalPaddingKey)
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
        self.workspaceId = workspaceId
        let requestedProfileID = profileID ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
        let resolvedProfileID = BrowserProfileStore.shared.profileDefinition(id: requestedProfileID) != nil
            ? requestedProfileID
            : BrowserProfileStore.shared.builtInDefaultProfileID
        self.profileID = resolvedProfileID
        self.historyStore = BrowserProfileStore.shared.historyStore(for: resolvedProfileID)
        self.insecureHTTPBypassHostOnce = BrowserInsecureHTTPSettings.normalizeHost(bypassInsecureHTTPHostOnce ?? "")
        self.bypassesRemoteWorkspaceProxy = bypassRemoteProxy
        self.remoteProxyEndpoint = bypassRemoteProxy ? nil : proxyEndpoint
        self.usesRemoteWorkspaceProxy = isRemoteWorkspace && !bypassRemoteProxy
        self.browserThemeMode = BrowserThemeSettings.mode()
        self.shouldPreloadInitialNavigationInBackground = preloadInitialNavigationInBackground
        self.isOmnibarVisible = omnibarVisible
        self.usesTransparentBackground = transparentBackground
        self.websiteDataStore = isRemoteWorkspace
            ? WKWebsiteDataStore(forIdentifier: remoteWebsiteDataStoreIdentifier ?? workspaceId)
            : BrowserProfileStore.shared.websiteDataStore(for: resolvedProfileID)
        let webView = Self.makeWebView(
            profileID: resolvedProfileID,
            websiteDataStore: websiteDataStore
        )
        self.webView = webView
        self.insecureHTTPAlertFactory = { NSAlert() }
        hiddenWebViewDiscardManager.delegate = self
        applyRemoteProxyConfigurationIfAvailable()
        BrowserProfileStore.shared.noteUsed(resolvedProfileID)

        // Set up navigation delegate
        let navDelegate = BrowserNavigationDelegate()
        navDelegate.openInNewTab = { [weak self] url in
            self?.openLinkInNewTab(url: url)
        }
        navDelegate.requestNavigation = { [weak self] request, intent in
            self?.requestNavigation(request, intent: intent)
        }
        navDelegate.presentAlert = { [weak self] alert, webView, completion, cancel in
            guard let self else {
                cancel()
                return
            }
            self.presentBrowserAlert(alert, in: webView, completion: completion, cancel: cancel)
        }
        navDelegate.shouldBlockInsecureHTTPNavigation = { [weak self] url in
            self?.shouldBlockInsecureHTTPNavigation(to: url) ?? false
        }
        navDelegate.handleBlockedInsecureHTTPNavigation = { [weak self] request, intent in
            self?.presentInsecureHTTPAlert(for: request, intent: intent, recordTypedNavigation: false)
        }
        navDelegate.didTerminateWebContentProcess = { [weak self] webView in
            self?.replaceWebViewAfterContentProcessTermination(for: webView)
        }
        // Set up download delegate for navigation-based downloads.
        // Downloads save to a temp file synchronously (no NSSavePanel during WebKit
        // callbacks), then show NSSavePanel after the download completes.
        let dlDelegate = BrowserDownloadDelegate()
        dlDelegate.onDownloadStarted = { [weak self] filename in
            guard let self else { return }
            self.beginDownloadActivity()
            NotificationCenter.default.post(
                name: .browserDownloadEventDidArrive,
                object: self,
                userInfo: [
                    "surfaceId": self.id,
                    "workspaceId": self.workspaceId,
                    "event": [
                        "type": "started",
                        "filename": filename
                    ]
                ]
            )
        }
        dlDelegate.onDownloadReadyToSave = { [weak self] in
            guard let self else { return }
            self.endDownloadActivity()
            NotificationCenter.default.post(
                name: .browserDownloadEventDidArrive,
                object: self,
                userInfo: [
                    "surfaceId": self.id,
                    "workspaceId": self.workspaceId,
                    "event": [
                        "type": "ready_to_save"
                    ]
                ]
            )
        }
        dlDelegate.onDownloadFailed = { [weak self] error in
            guard let self else { return }
            self.endDownloadActivity()
            NotificationCenter.default.post(
                name: .browserDownloadEventDidArrive,
                object: self,
                userInfo: [
                    "surfaceId": self.id,
                    "workspaceId": self.workspaceId,
                    "event": [
                        "type": "failed",
                        "error": error.localizedDescription
                    ]
                ]
            )
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
            self?.requestNavigation(request, intent: intent)
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
            return browserFallbackInteractiveModalHostWindow()
        }

        if let initialRequest {
            hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
            currentURL = initialRequest.url
            shouldRenderWebView = renderInitialNavigation
            guard renderInitialNavigation else { return }
            if let url = initialRequest.url,
               insecureHTTPBypassHostOnce == nil,
               shouldBlockInsecureHTTPNavigation(to: url) {
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
            navigate(to: url)
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
        applyRemoteProxyConfigurationIfAvailable()
        resumePendingRemoteNavigationIfNeeded()
    }

    func setRemoteWorkspaceStatus(_ status: BrowserRemoteWorkspaceStatus?) {
        guard remoteWorkspaceStatus != status else { return }
        remoteWorkspaceStatus = status
    }

    private func applyRemoteProxyConfigurationIfAvailable() {
        guard #available(macOS 14.0, *) else { return }

        let store = webView.configuration.websiteDataStore
        guard let endpoint = remoteProxyEndpoint else {
            store.proxyConfigurations = []
            return
        }

        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              endpoint.port > 0 && endpoint.port <= 65535,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            store.proxyConfigurations = []
            return
        }

        let nwEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let socks = ProxyConfiguration(socksv5Proxy: nwEndpoint)
        let connect = ProxyConfiguration(httpCONNECTProxy: nwEndpoint)
        store.proxyConfigurations = [socks, connect]
    }

    private func beginDownloadActivity() {
        let apply = {
            let wasDownloading = self.isDownloading
            self.activeDownloadCount += 1
            self.isDownloading = self.activeDownloadCount > 0
            if !wasDownloading && self.isDownloading {
                self.reevaluateHiddenWebViewDiscardScheduling(reason: "download.started")
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func endDownloadActivity() {
        let apply = {
            self.activeDownloadCount = max(0, self.activeDownloadCount - 1)
            self.isDownloading = self.activeDownloadCount > 0
            if !self.isDownloading {
                self.scheduleHiddenWebViewDiscardIfNeeded(reason: "download.finished")
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
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
        applyRemoteProxyConfigurationIfAvailable()
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
        let desiredZoom = max(minPageZoom, min(maxPageZoom, previousWebView.pageZoom))
        let restoreDeveloperTools = preferredDeveloperToolsVisible || isDeveloperToolsVisible()

        invalidateSearchFocusRequests(reason: "profileSwitch")
        searchState = nil

        _ = hideDeveloperTools()
        cancelDeveloperToolsRestoreRetry()

        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        clearWebContentTerminationRecovery()
        clearBrowserFocusMode(reason: "profileSwitch")
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        cancelPendingInteractiveBrowserPrompts(reason: "profileSwitch")
        closeBackgroundPreloadHost(reason: "profileSwitch")
        BrowserWindowPortalRegistry.detach(webView: previousWebView)
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
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken &+= 1
    }

    func sessionNavigationHistorySnapshot() -> (
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String]
    ) {
        realignRestoredSessionHistoryToLiveCurrentIfPossible()

        let nativeBack = webView.backForwardList.backList.compactMap {
            Self.serializableSessionHistoryURLString($0.url)
        }
        let nativeForward = webView.backForwardList.forwardList.compactMap {
            Self.serializableSessionHistoryURLString($0.url)
        }

        if usesRestoredSessionHistory {
            let back = restoredBackHistoryStack.compactMap { Self.serializableSessionHistoryURLString($0) }
            // `restoredForwardHistoryStack` stores nearest-forward entries at the end.
            let restoredForward = restoredForwardHistoryStack.reversed().compactMap {
                Self.serializableSessionHistoryURLString($0)
            }

            if isLiveSessionHistoryAlignedWithRestoredCurrent {
                return (
                    back,
                    restoredForward.isEmpty ? nativeForward : restoredForward
                )
            }

            return (back + nativeBack, nativeForward)
        }

        return (nativeBack, nativeForward)
    }

    private func resolvedLiveSessionHistoryURL() -> URL? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url),
           Self.serializableSessionHistoryURLString(webViewURL) != nil {
            return webViewURL
        }
        if let currentURL,
           Self.serializableSessionHistoryURLString(currentURL) != nil {
            return currentURL
        }
        return nil
    }

    private var isLiveSessionHistoryAlignedWithRestoredCurrent: Bool {
        let liveCurrent = Self.serializableSessionHistoryURLString(resolvedLiveSessionHistoryURL())
        let restoredCurrent = Self.serializableSessionHistoryURLString(restoredHistoryCurrentURL)
        guard let liveCurrent, let restoredCurrent else { return true }
        return liveCurrent == restoredCurrent
    }

    private func realignRestoredSessionHistoryToLiveCurrentIfPossible() {
        guard usesRestoredSessionHistory else { return }
        guard let liveCurrent = resolvedLiveSessionHistoryURL(),
              let liveCurrentString = Self.serializableSessionHistoryURLString(liveCurrent) else {
            return
        }
        guard Self.serializableSessionHistoryURLString(restoredHistoryCurrentURL) != liveCurrentString else {
            return
        }

        let restoredBack = restoredBackHistoryStack.compactMap { Self.serializableSessionHistoryURLString($0) }
        let restoredForward = restoredForwardHistoryStack.reversed().compactMap {
            Self.serializableSessionHistoryURLString($0)
        }
        let restoredCurrent = Self.serializableSessionHistoryURLString(restoredHistoryCurrentURL)

        if let backIndex = restoredBack.lastIndex(of: liveCurrentString) {
            let newBack = Array(restoredBack[..<backIndex])
            var newForward = Array(restoredBack[(backIndex + 1)...])
            if let restoredCurrent {
                newForward.append(restoredCurrent)
            }
            newForward.append(contentsOf: restoredForward)

            restoredBackHistoryStack = Self.sanitizedSessionHistoryURLs(newBack)
            restoredForwardHistoryStack = Array(Self.sanitizedSessionHistoryURLs(newForward).reversed())
            restoredHistoryCurrentURL = liveCurrent
            refreshNavigationAvailability()
            return
        }

        if let forwardIndex = restoredForward.firstIndex(of: liveCurrentString) {
            var newBack = restoredBack
            if let restoredCurrent {
                newBack.append(restoredCurrent)
            }
            newBack.append(contentsOf: restoredForward[..<forwardIndex])
            let newForward = Array(restoredForward[(forwardIndex + 1)...])

            restoredBackHistoryStack = Self.sanitizedSessionHistoryURLs(newBack)
            restoredForwardHistoryStack = Array(Self.sanitizedSessionHistoryURLs(newForward).reversed())
            restoredHistoryCurrentURL = liveCurrent
            refreshNavigationAvailability()
            return
        }

        guard !restoredForwardHistoryStack.isEmpty else { return }
#if DEBUG
        cmuxDebugLog(
            "browser.history.restore.forward.clear panel=\(id.uuidString.prefix(5)) " +
            "current=\(liveCurrentString)"
        )
#endif
        restoredForwardHistoryStack.removeAll(keepingCapacity: false)
        refreshNavigationAvailability()
    }

    func restoreSessionNavigationHistory(
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String],
        currentURLString: String?
    ) {
        let restoredBack = Self.sanitizedSessionHistoryURLs(backHistoryURLStrings)
        let restoredForward = Self.sanitizedSessionHistoryURLs(forwardHistoryURLStrings)
        let restoredCurrent = Self.sanitizedSessionHistoryURL(currentURLString)
        guard !restoredBack.isEmpty || !restoredForward.isEmpty || restoredCurrent != nil else { return }

        usesRestoredSessionHistory = true
        restoredBackHistoryStack = restoredBack
        // Store nearest-forward entries at the end to make stack pop operations trivial.
        restoredForwardHistoryStack = Array(restoredForward.reversed())
        restoredHistoryCurrentURL = restoredCurrent
        refreshNavigationAvailability()
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
            shouldRenderWebView = shouldRenderRestoredWebView
            guard shouldRenderRestoredWebView else {
                refreshNavigationAvailability()
                return
            }
            navigateWithoutInsecureHTTPPrompt(
                to: diffURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: false
            )
            return
        }

        let restoredURL = Self.sanitizedSessionHistoryURL(snapshot.urlString)
        let shouldRenderRestoredWebView = snapshot.shouldRenderWebView && BrowserAvailabilitySettings.isEnabled()
        hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(snapshot.shouldRenderWebView)
        setMuted(snapshot.isMuted)
        setOmnibarVisible(snapshot.omnibarVisible ?? true)

        restoreSessionNavigationHistory(
            backHistoryURLStrings: snapshot.backHistoryURLStrings ?? [],
            forwardHistoryURLStrings: snapshot.forwardHistoryURLStrings ?? [],
            currentURLString: snapshot.urlString
        )

        currentURL = restoredURL
        shouldRenderWebView = shouldRenderRestoredWebView

        guard shouldRenderRestoredWebView, let restoredURL else {
            refreshNavigationAvailability()
            return
        }

        navigateWithoutInsecureHTTPPrompt(
            to: restoredURL,
            recordTypedNavigation: false,
            preserveRestoredSessionHistory: true
        )
    }

    func shouldRenderWebViewForSessionSnapshot() -> Bool {
        // Diff viewer URLs are "temporary" so `preferredURLStringForSessionSnapshot()`
        // is nil, but they are restorable via their token, so honor their render
        // intent too (otherwise a restored diff surface never navigates).
        guard preferredURLStringForSessionSnapshot() != nil || diffViewerSessionComponents() != nil else {
            return false
        }
        return hiddenWebViewDiscardManager.restoredSessionShouldRenderWebView ?? shouldRenderWebView
    }

    func shouldPersistSessionSnapshot() -> Bool {
        // Diff viewer surfaces are otherwise treated as temporary. Persist them
        // only when they can actually be restored via the custom scheme (a
        // local-only, non-pending manifest); otherwise persisting would leave a
        // blank panel on restart with no URL to fall back to.
        if let components = diffViewerSessionComponents() {
            return CmuxDiffViewerURLSchemeHandler.shared.diffViewerRestorable(
                token: components.token,
                requestPath: components.requestPath
            )
        }
        guard !Self.isTemporarySessionHistoryURL(webView.url),
              !Self.isTemporarySessionHistoryURL(currentURL),
              !Self.isTemporarySessionHistoryURL(restoredHistoryCurrentURL) else {
            return false
        }
        return true
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
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url),
           let value = Self.serializableSessionHistoryURLString(webViewURL) {
            return value
        }
        if let currentURL,
           let value = Self.serializableSessionHistoryURLString(currentURL) {
            return value
        }
        return nil
    }

    private func setupObservers(for webView: WKWebView) {
        let observedWebViewInstanceID = webViewInstanceID

        // URL changes
        let urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, change in
            let observedURL = change.newValue ?? webView.url
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                guard !self.isMainFrameProvisionalNavigationActive else { return }
                self.currentURL = Self.remoteProxyDisplayURL(for: observedURL)
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
            usesTransparentWindow: cmuxShouldUseTransparentBackgroundWindow()
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
        let attemptedURL = Self.remoteProxyDisplayURL(for: navigationDelegate?.lastAttemptedURL)
            ?? navigationDelegate?.lastAttemptedURL
        let liveURL = Self.remoteProxyDisplayURL(for: oldWebView.url)
            ?? currentURL
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
        let desiredZoom = max(minPageZoom, min(maxPageZoom, oldWebView.pageZoom))
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
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        loadingGeneration &+= 1
        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil
        isLoading = false
        estimatedProgress = 0
        cancelPendingInteractiveBrowserPrompts(reason: reason)
        closeBackgroundPreloadHost(reason: reason)
        BrowserWindowPortalRegistry.detach(webView: oldWebView)
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
    func recoverTerminatedWebContent(reason: String = "manual") -> Bool {
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
            preserveRestoredSessionHistory: true
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
            let urlString = Self.remoteProxyDisplayURL(for: webView.url)?.absoluteString ?? currentURL?.absoluteString
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

        webView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        navigationDelegate = nil
        uiDelegate = nil
        webViewDidRequestClose = nil
        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        faviconTask?.cancel()
        faviconTask = nil
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

    private func refreshFavicon(from webView: WKWebView) {
        faviconTask?.cancel()
        faviconTask = nil

        guard let pageURL = webView.url else { return }
        guard let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        faviconRefreshGeneration &+= 1
        let refreshGeneration = faviconRefreshGeneration
        let refreshWebViewInstanceID = webViewInstanceID

        faviconTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            guard self.isCurrentWebView(webView, instanceID: refreshWebViewInstanceID) else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }
#if DEBUG
            cmuxDebugLog(
                "browser.favicon.begin " +
                "panel=\(id.uuidString.prefix(5)) " +
                "page=\(pageURL.absoluteString)"
            )
#endif

            // Try to discover the best icon URL from the document.
            let js = """
            (() => {
              const links = Array.from(document.querySelectorAll(
                'link[rel~=\"icon\"], link[rel=\"shortcut icon\"], link[rel=\"apple-touch-icon\"], link[rel=\"apple-touch-icon-precomposed\"]'
              ));
              function score(link) {
                const v = (link.sizes && link.sizes.value) ? link.sizes.value : '';
                if (v === 'any') return 1000;
                let max = 0;
                for (const part of v.split(/\\s+/)) {
                  const m = part.match(/(\\d+)x(\\d+)/);
                  if (!m) continue;
                  const a = parseInt(m[1], 10);
                  const b = parseInt(m[2], 10);
                  if (Number.isFinite(a)) max = Math.max(max, a);
                  if (Number.isFinite(b)) max = Math.max(max, b);
                }
                return max;
              }
              links.sort((a, b) => score(b) - score(a));
              return links[0]?.href || '';
            })();
            """

            var discoveredURL: URL?
            if let href = await self.evaluateJavaScriptString(
                js,
                in: webView,
                timeoutNanoseconds: 400_000_000
            ) {
                let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let u = URL(string: trimmed) {
                    discoveredURL = u
                }
            }
            guard self.isCurrentWebView(webView, instanceID: refreshWebViewInstanceID) else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }

            // SPAs often inject <link rel="icon"> via JavaScript after the initial
            // HTML loads. If no link tag was found, wait briefly and retry once to
            // give client-side scripts time to add the tag.
            if discoveredURL == nil {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard self.isCurrentWebView(webView, instanceID: refreshWebViewInstanceID) else { return }
                guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }
                if let href = await self.evaluateJavaScriptString(
                    js,
                    in: webView,
                    timeoutNanoseconds: 400_000_000
                ) {
                    let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let u = URL(string: trimmed) {
                        discoveredURL = u
                    }
                }
                guard self.isCurrentWebView(webView, instanceID: refreshWebViewInstanceID) else { return }
                guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }
            }

            let fallbackURL = URL(string: "/favicon.ico", relativeTo: pageURL)
            let iconURL = discoveredURL ?? fallbackURL
            guard let iconURL else { return }
#if DEBUG
            cmuxDebugLog(
                "browser.favicon.iconURL " +
                "panel=\(id.uuidString.prefix(5)) " +
                "discovered=\(discoveredURL?.absoluteString ?? "<nil>") " +
                "fallback=\(fallbackURL?.absoluteString ?? "<nil>") " +
                "chosen=\(iconURL.absoluteString)"
            )
#endif

            // Avoid repeated fetches.
            let iconURLString = iconURL.absoluteString
            if iconURLString == lastFaviconURLString, faviconPNGData != nil {
#if DEBUG
                cmuxDebugLog(
                    "browser.favicon.skipCached " +
                    "panel=\(id.uuidString.prefix(5)) " +
                    "icon=\(iconURLString)"
                )
#endif
                return
            }
            lastFaviconURLString = iconURLString

            var req = URLRequest(url: iconURL)
            req.timeoutInterval = 2.0
            req.cachePolicy = .returnCacheDataElseLoad
            req.setValue(BrowserUserAgentSettings.safariUserAgent, forHTTPHeaderField: "User-Agent")
            let effectiveRequest = remoteProxyPreparedRequest(from: req, logScope: "faviconRewrite")

            let data: Data
            let response: URLResponse
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
                    (data, response) = try await remoteSession.data(for: effectiveRequest)
                } else {
#if DEBUG
                    cmuxDebugLog(
                        "browser.favicon.fetch " +
                        "panel=\(id.uuidString.prefix(5)) " +
                        "via=direct " +
                        "url=\(effectiveRequest.url?.absoluteString ?? "<nil>")"
                    )
#endif
                    (data, response) = try await URLSession.shared.data(for: effectiveRequest)
                }
            } catch {
#if DEBUG
                cmuxDebugLog(
                    "browser.favicon.fetchError " +
                    "panel=\(id.uuidString.prefix(5)) " +
                    "error=\(String(describing: error))"
                )
#endif
                return
            }
            guard self.isCurrentWebView(webView, instanceID: refreshWebViewInstanceID) else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
#if DEBUG
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                cmuxDebugLog(
                    "browser.favicon.badResponse " +
                    "panel=\(id.uuidString.prefix(5)) " +
                    "status=\(status)"
                )
#endif
                return
            }
#if DEBUG
            cmuxDebugLog(
                "browser.favicon.response " +
                "panel=\(id.uuidString.prefix(5)) " +
                "status=\(http.statusCode) " +
                "bytes=\(data.count)"
            )
#endif

            // Use >= 2x the rendered point size so we don't upscale (blurry) on Retina.
            guard let png = Self.makeFaviconPNGData(from: data, targetPx: 32) else {
#if DEBUG
                cmuxDebugLog(
                    "browser.favicon.decodeFailed " +
                    "panel=\(id.uuidString.prefix(5)) " +
                    "bytes=\(data.count)"
                )
#endif
                return
            }
            // Only update if we got a real icon; keep the old one otherwise to avoid flashes.
            faviconPNGData = png
#if DEBUG
            cmuxDebugLog(
                "browser.favicon.ready " +
                "panel=\(id.uuidString.prefix(5)) " +
                "pngBytes=\(png.count)"
            )
#endif
        }
    }

    private func isCurrentFaviconRefresh(generation: Int) -> Bool {
        guard !Task.isCancelled else { return false }
        return generation == faviconRefreshGeneration
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

    @MainActor
    private static func makeFaviconPNGData(from raw: Data, targetPx: Int) -> Data? {
        guard let image = NSImage(data: raw) else { return nil }

        let px = max(16, min(128, targetPx))
        let size = NSSize(width: px, height: px)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        ctx?.imageInterpolation = .high
        ctx?.shouldAntialias = true
        NSGraphicsContext.current = ctx

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        // Aspect-fit into the target square.
        let srcSize = image.size
        let scale = min(size.width / max(1, srcSize.width), size.height / max(1, srcSize.height))
        let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
        let drawOrigin = NSPoint(x: (size.width - drawSize.width) / 2.0, y: (size.height - drawSize.height) / 2.0)
        // Align to integral pixels to avoid soft edges at small sizes.
        let drawRect = NSRect(
            x: round(drawOrigin.x),
            y: round(drawOrigin.y),
            width: round(drawSize.width),
            height: round(drawSize.height)
        )

        image.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: srcSize),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        return rep.representation(using: .png, properties: [:])
    }

    private func handleWebViewLoadingChanged(_ newValue: Bool) {
        if newValue {
            cancelHiddenWebViewDiscard()
            // Any new load invalidates older favicon fetches, even for same-URL reloads.
            faviconRefreshGeneration &+= 1
            faviconTask?.cancel()
            faviconTask = nil
            lastFaviconURLString = nil
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

    /// Navigate to a URL
    func navigate(to url: URL, recordTypedNavigation: Bool = false) {
        let request = URLRequest(url: url)
        if shouldBlockInsecureHTTPNavigation(to: url) {
            presentInsecureHTTPAlert(for: request, intent: .currentTab, recordTypedNavigation: recordTypedNavigation)
            return
        }
        navigateWithoutInsecureHTTPPrompt(request: request, recordTypedNavigation: recordTypedNavigation)
    }

    private func navigateWithoutInsecureHTTPPrompt(
        to url: URL,
        recordTypedNavigation: Bool,
        preserveRestoredSessionHistory: Bool = false
    ) {
        let request = URLRequest(url: url)
        navigateWithoutInsecureHTTPPrompt(
            request: request,
            recordTypedNavigation: recordTypedNavigation,
            preserveRestoredSessionHistory: preserveRestoredSessionHistory
        )
    }

    private func navigateWithoutInsecureHTTPPrompt(
        request: URLRequest,
        recordTypedNavigation: Bool,
        preserveRestoredSessionHistory: Bool = false
    ) {
        guard let url = request.url else { return }
        cancelHiddenWebViewDiscard()
        clearWebViewDiscardState(reason: "navigation")
        if usesRemoteWorkspaceProxy, remoteProxyEndpoint == nil {
            pendingRemoteNavigation = PendingRemoteNavigation(
                request: request,
                recordTypedNavigation: recordTypedNavigation,
                preserveRestoredSessionHistory: preserveRestoredSessionHistory
            )
            hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
            currentURL = Self.remoteProxyDisplayURL(for: url) ?? url
            navigationDelegate?.lastAttemptedURL = url
            refreshBackgroundAppearance()
            shouldRenderWebView = true
            return
        }
        performNavigation(
            request: request,
            originalURL: url,
            recordTypedNavigation: recordTypedNavigation,
            preserveRestoredSessionHistory: preserveRestoredSessionHistory
        )
    }

    private func resumePendingRemoteNavigationIfNeeded() {
        guard remoteProxyEndpoint != nil,
              let navigation = pendingRemoteNavigation else {
            return
        }
        guard let originalURL = navigation.request.url else {
            pendingRemoteNavigation = nil
            reevaluateHiddenWebViewDiscardScheduling(reason: "pending_remote_navigation_cleared")
            return
        }
        performNavigation(
            request: navigation.request,
            originalURL: originalURL,
            recordTypedNavigation: navigation.recordTypedNavigation,
            preserveRestoredSessionHistory: navigation.preserveRestoredSessionHistory
        )
        pendingRemoteNavigation = nil
    }

    private func performNavigation(
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
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
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
        browserLoadRequest(effectiveRequest, in: webView)
    }

    private func remoteProxyPreparedRequest(from request: URLRequest, logScope: String) -> URLRequest {
        guard remoteProxyEndpoint != nil else { return request }
        guard let url = request.url else { return request }
        guard let rewrittenURL = Self.remoteProxyLoopbackAliasURL(for: url) else { return request }

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
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, endpoint.port > 0, endpoint.port <= 65535 else { return nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 2.0
        configuration.timeoutIntervalForResource = 4.0
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: host,
            kCFNetworkProxiesSOCKSPort as String: endpoint.port,
        ]
        return URLSession(configuration: configuration)
    }

    private static func remoteProxyDisplayURL(for url: URL?) -> URL? {
        guard let url else { return nil }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return url }
        guard let displayHost = RemoteLoopbackProxyAlias.localhostFamilyHost(
            forAliasHost: host,
            aliasHost: RemoteLoopbackProxyAlias.aliasHost
        ) else { return url }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = displayHost
        return components?.url ?? url
    }

    private static func remoteProxyLoopbackAliasURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" else { return nil }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return nil }
        guard RemoteLoopbackProxyAlias.isLoopbackHost(host) else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = RemoteLoopbackProxyAlias.browserAliasHost(
            forLoopbackHost: host,
            aliasHost: RemoteLoopbackProxyAlias.aliasHost
        )
        return components?.url
    }

    /// Navigate with smart URL/search detection
    /// - If input looks like a URL, navigate to it
    /// - Otherwise, perform a web search
    func navigateSmart(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let url = resolveNavigableURL(from: trimmed) {
            navigate(to: url, recordTypedNavigation: true)
            return
        }

        let searchConfiguration = BrowserSearchSettings.currentConfiguration()
        guard let searchURL = searchConfiguration.searchURL(query: trimmed) else { return }
        navigate(to: searchURL)
    }

    func resolveNavigableURL(from input: String) -> URL? {
        resolveBrowserNavigableURL(input)
    }

    private func shouldBlockInsecureHTTPNavigation(to url: URL) -> Bool {
        if consumeOneTimeInsecureHTTPBypassIfNeeded(for: url) {
            return false
        }
        return browserShouldBlockInsecureHTTPURL(url)
    }

    @discardableResult
    private func consumeOneTimeInsecureHTTPBypassIfNeeded(for url: URL) -> Bool {
        browserShouldConsumeOneTimeInsecureHTTPBypass(url, bypassHostOnce: &insecureHTTPBypassHostOnce)
    }

    private func requestNavigation(_ request: URLRequest, intent: BrowserInsecureHTTPNavigationIntent) {
        guard let url = request.url else { return }
        if shouldBlockInsecureHTTPNavigation(to: url) {
            presentInsecureHTTPAlert(for: request, intent: intent, recordTypedNavigation: false)
            return
        }
        switch intent {
        case .currentTab:
            navigateWithoutInsecureHTTPPrompt(request: request, recordTypedNavigation: false)
        case .newTab:
            openLinkInNewTab(request: request)
        }
    }

    private func presentInsecureHTTPAlert(
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
            self?.handleInsecureHTTPAlertResponse(
                response,
                alert: alert,
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

    private func handleInsecureHTTPAlertResponse(
        _ response: NSApplication.ModalResponse,
        alert: NSAlert?,
        host: String,
        request: URLRequest,
        url: URL,
        intent: BrowserInsecureHTTPNavigationIntent,
        recordTypedNavigation: Bool
    ) {
        if browserShouldPersistInsecureHTTPAllowlistSelection(
            response: response,
            suppressionEnabled: alert?.suppressionButton?.state == .on
        ) {
            BrowserInsecureHTTPSettings.addAllowedHost(host)
        }
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(url)
        case .alertSecondButtonReturn:
            switch intent {
            case .currentTab:
                insecureHTTPBypassHostOnce = host
                navigateWithoutInsecureHTTPPrompt(request: request, recordTypedNavigation: recordTypedNavigation)
            case .newTab:
                openLinkInNewTab(request: request, bypassInsecureHTTPHostOnce: host)
            }
        default:
            return
        }
    }

    deinit {
        hiddenWebViewDiscardManager.stop()
        developerToolsRestoreRetryWorkItem?.cancel()
        developerToolsRestoreRetryWorkItem = nil
        developerToolsTransitionSettleWorkItem?.cancel()
        developerToolsTransitionSettleWorkItem = nil
        developerToolsVisibilityLossCheckWorkItem?.cancel()
        developerToolsVisibilityLossCheckWorkItem = nil
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
            hasPendingRemoteNavigation: pendingRemoteNavigation != nil,
            hasCurrentURL: (currentURL ?? Self.remoteProxyDisplayURL(for: webView.url)) != nil,
            isLoading: isLoading,
            webViewIsLoading: webView.isLoading,
            hasActiveMainFrameProvisionalNavigation: isMainFrameProvisionalNavigationActive,
            isDownloading: isDownloading,
            activeDownloadCount: activeDownloadCount,
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
        restoredHistoryCurrentURL != nil ||
        !restoredBackHistoryStack.isEmpty ||
        !restoredForwardHistoryStack.isEmpty ||
        estimatedProgress > 0 ||
        isLoading ||
        isDownloading ||
        activeDownloadCount != 0 ||
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
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        loadingGeneration &+= 1
        activeDownloadCount = 0
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
        lastFaviconURLString = nil
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

private func browserBareHostCandidate(_ lowercasedInput: String) -> String {
    let end = lowercasedInput.firstIndex { character in
        character == ":" || character == "/" || character == "?" || character == "#"
    } ?? lowercasedInput.endIndex
    return String(lowercasedInput[..<end])
}

func resolveBrowserNavigableURL(_ input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !trimmed.contains(" ") else { return nil }

    // Check localhost/loopback before generic URL parsing because
    // URL(string: "localhost:3777") treats "localhost" as a scheme.
    let lower = trimmed.lowercased()
    let bareHost = browserBareHostCandidate(lower)
    if lower.hasPrefix("localhost") ||
        lower.hasPrefix("127.0.0.1") ||
        lower.hasPrefix("[::1]") ||
        (bareHost != ".localhost" && bareHost.hasSuffix(".localhost")) {
        return URL(string: "http://\(trimmed)")
    }

    if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
        if scheme == "http" || scheme == "https" {
            return url
        }
        if scheme == "file", url.isFileURL, url.path.hasPrefix("/") {
            return url
        }
        return nil
    }

    if trimmed.contains(":") || trimmed.contains("/") {
        return URL(string: "https://\(trimmed)")
    }

    if trimmed.contains(".") {
        return URL(string: "https://\(trimmed)")
    }

    return nil
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
        if usesRestoredSessionHistory {
            realignRestoredSessionHistoryToLiveCurrentIfPossible()

            if (isLiveSessionHistoryAlignedWithRestoredCurrent || !nativeCanGoBack),
               let targetURL = restoredBackHistoryStack.popLast() {
                if let current = resolvedCurrentSessionHistoryURL() {
                    restoredForwardHistoryStack.append(current)
                }
                restoredHistoryCurrentURL = targetURL
                refreshNavigationAvailability()
                navigateWithoutInsecureHTTPPrompt(
                    to: targetURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: true
                )
                return
            }

            if nativeCanGoBack {
                webView.goBack()
                return
            }

            refreshNavigationAvailability()
            return
        }

        webView.goBack()
    }

    /// Go forward in history
    func goForward() {
        guard canGoForward else { return }
        reactivateDiscardedWebViewWithoutNavigation(reason: "goForward")
        cancelInFlightNavigationBeforeHistoryTraversal()
        if usesRestoredSessionHistory {
            realignRestoredSessionHistoryToLiveCurrentIfPossible()

            if nativeCanGoForward {
                webView.goForward()
                return
            }

            guard let targetURL = restoredForwardHistoryStack.popLast() else {
                refreshNavigationAvailability()
                return
            }
            if let current = resolvedCurrentSessionHistoryURL() {
                restoredBackHistoryStack.append(current)
            }
            restoredHistoryCurrentURL = targetURL
            refreshNavigationAvailability()
            navigateWithoutInsecureHTTPPrompt(
                to: targetURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true
            )
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
        guard let seed = browserNewTabNavigationSeed(
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
            ?? Self.remoteProxyDisplayURL(for: webView.url)
            ?? currentURL
    }

    var bypassesRemoteWorkspaceProxyForTabDuplication: Bool {
        bypassesRemoteWorkspaceProxy
    }

    /// Reload the current page
    func reload() {
        if recoverTerminatedWebContent(reason: "reload") {
            return
        }
        if restoreDiscardedWebViewIfNeeded(reason: "reload") {
            return
        }
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        if Self.serializableSessionHistoryURLString(Self.remoteProxyDisplayURL(for: webView.url)) == nil {
            let fallbackURL = resolvedCurrentSessionHistoryURL()
                ?? Self.remoteProxyDisplayURL(for: navigationDelegate?.lastAttemptedURL)

            if let fallbackURL,
               Self.serializableSessionHistoryURLString(fallbackURL) != nil {
                navigateWithoutInsecureHTTPPrompt(
                    to: fallbackURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: usesRestoredSessionHistory
                )
                return
            }
        }
        webView.reload()
    }

    /// Stop loading
    func stopLoading() {
        webView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
    }

    private static func windowContainsInspectorViews(_ root: NSView) -> Bool {
        if cmuxIsWebInspectorObject(root) {
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
                return self.closeDeveloperToolsFromDetachedInspectorWindowWillClose(window)
            }
            guard handledDetachedInspector else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.preferredDeveloperToolsPresentation == .detached else { return }
                guard self.preferredDeveloperToolsVisible else { return }
                guard !self.isDeveloperToolsVisible() else { return }
                self.developerToolsDetachedOpenGraceDeadline = nil
                self.setPreferredDeveloperToolsVisible(false)
                self.reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
                self.cancelDeveloperToolsRestoreRetry()
#if DEBUG
                cmuxDebugLog(
                    "browser.devtools detachedClose.manual panel=\(self.id.uuidString.prefix(5)) " +
                    "\(self.debugDeveloperToolsStateSummary()) \(self.debugDeveloperToolsGeometrySummary())"
                )
#endif
            }
        }
    }

    @discardableResult
    private func closeDeveloperToolsFromDetachedInspectorWindowWillClose(_ window: NSWindow) -> Bool {
        closeDeveloperToolsFromDetachedInspectorWindow(window, source: "willClose")
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

        let shouldForceRefresh = forceDeveloperToolsRefreshOnNextAttach
        forceDeveloperToolsRefreshOnNextAttach = false

        let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
        if visible {
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
        cmuxWithWindowFirstResponderBypass {
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
        applyPageZoom(webView.pageZoom + pageZoomStep)
    }

    @discardableResult
    func zoomOut() -> Bool {
        applyPageZoom(webView.pageZoom - pageZoomStep)
    }

    @discardableResult
    func resetZoom() -> Bool {
        applyPageZoom(1.0)
    }

    func currentPageZoomFactor() -> CGFloat {
        webView.pageZoom
    }

    @discardableResult
    func setPageZoomFactor(_ pageZoom: CGFloat) -> Bool {
        let clamped = max(minPageZoom, min(maxPageZoom, pageZoom))
        return applyPageZoom(clamped)
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
        clearBrowserFocusMode(reason: "startFind")
        preferredFocusIntent = .findField
        let created = searchState == nil
        let recoveredNeedle = created ? lastSearchNeedle : ""
        if created { searchState = BrowserSearchState(needle: recoveredNeedle) }
        let shouldSelectAll = created && !recoveredNeedle.isEmpty
        pendingAddressBarFocusRequestId = nil
        pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: id)
        let generation = beginSearchFocusRequest(reason: "startFind")
        postBrowserSearchFocusNotification(reason: "immediate", generation: generation, selectAll: shouldSelectAll)
        // Re-post because portal overlay mount can race first responder focus.
        DispatchQueue.main.async { [weak self] in
            self?.postBrowserSearchFocusNotification(reason: "async0", generation: generation, selectAll: shouldSelectAll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.postBrowserSearchFocusNotification(reason: "async50ms", generation: generation, selectAll: shouldSelectAll)
        }
    }

    private func postBrowserSearchFocusNotification(reason: String, generation: UInt64, selectAll: Bool) {
        guard canApplySearchFocusRequest(generation) else {
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = try? await self.webView.evaluateJavaScript(BrowserFindJavaScript.nextScript())
            self.parseFindResult(result)
        }
    }

    func findPrevious() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = try? await self.webView.evaluateJavaScript(BrowserFindJavaScript.previousScript())
            self.parseFindResult(result)
        }
    }

    func hideFind() {
        let shouldRestoreWebViewFocus = searchState != nil && preferredFocusIntent == .findField
        invalidateSearchFocusRequests(reason: "hideFind")
        searchState = nil
        if shouldRestoreWebViewFocus { focus() }
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
        guard let state = searchState else { return }
        state.total = nil
        state.selected = nil
        if replaySearch, !state.needle.isEmpty {
            executeFindSearch(state.needle)
        }
        postBrowserSearchFocusNotification(reason: "restoreAfterNavigation", generation: searchFocusRequestGeneration, selectAll: false)
    }

    private func executeFindSearch(_ needle: String) {
        guard !needle.isEmpty else {
            executeFindClear()
            searchState?.selected = nil
            searchState?.total = nil
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let js = BrowserFindJavaScript.searchScript(query: needle)
            do {
                let result = try await self.webView.evaluateJavaScript(js)
                self.parseFindResult(result)
            } catch {
                NSLog("Find: browser JS search error: %@", error.localizedDescription)
            }
        }
    }

    private func executeFindClear() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.webView.evaluateJavaScript(BrowserFindJavaScript.clearScript())
            } catch {
                NSLog("Find: browser JS clear error: %@", error.localizedDescription)
            }
        }
    }

    private func parseFindResult(_ result: Any?) {
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = json["total"] as? Int,
              let current = json["current"] as? Int,
              total >= 0, current >= 0 else {
            return
        }
        searchState?.total = UInt(total)
        searchState?.selected = total > 0 ? UInt(current) : nil
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
        generation != 0 &&
            generation == searchFocusRequestGeneration &&
            searchState != nil &&
            preferredFocusIntent == .findField
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
           browserOmnibarPanelId(for: responder) == id {
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
            guard browserOmnibarPanelId(for: window.firstResponder) == id else {
                clearAddressBarFocusTrackingForYield()
                return false
            }
            browserPrepareOmnibarForProgrammaticBlur(panelId: id, responder: window.firstResponder)
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

    @discardableResult
    private func beginSearchFocusRequest(reason: String) -> UInt64 {
        searchFocusRequestGeneration &+= 1
#if DEBUG
        cmuxDebugLog(
            "browser.find.focusLease.begin panel=\(id.uuidString.prefix(5)) " +
            "generation=\(searchFocusRequestGeneration) reason=\(reason)"
        )
#endif
        return searchFocusRequestGeneration
    }

    private func invalidateSearchFocusRequests(reason: String) {
        searchFocusRequestGeneration &+= 1
#if DEBUG
        cmuxDebugLog(
            "browser.find.focusLease.invalidate panel=\(id.uuidString.prefix(5)) " +
            "generation=\(searchFocusRequestGeneration) reason=\(reason)"
        )
#endif
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
        webView.evaluateJavaScript(Self.addressBarFocusCaptureScript) { [weak self] result, error in
#if DEBUG
            guard let self else { return }
            if let error {
                cmuxDebugLog(
                    "browser.focus.addressBar.capture panel=\(self.id.uuidString.prefix(5)) " +
                    "result=error message=\(error.localizedDescription)"
                )
                return
            }
            let resultValue = (result as? String) ?? "unknown"
            cmuxDebugLog(
                "browser.focus.addressBar.capture panel=\(self.id.uuidString.prefix(5)) " +
                "result=\(resultValue)"
            )
#else
            _ = self
            _ = result
            _ = error
#endif
        }
    }

    private enum AddressBarPageFocusRestoreStatus: String {
        case restored
        case noState = "no_state"
        case missingTarget = "missing_target"
        case notFocused = "not_focused"
        case error
    }

    private static func addressBarPageFocusRestoreStatus(
        from result: Any?,
        error: Error?
    ) -> AddressBarPageFocusRestoreStatus {
        if error != nil { return .error }
        guard let raw = result as? String else { return .error }
        return AddressBarPageFocusRestoreStatus(rawValue: raw) ?? .error
    }

    func invalidateAddressBarPageFocusRestoreAttempts() {
        addressBarFocusRestoreGeneration &+= 1
#if DEBUG
        cmuxDebugLog(
            "browser.focus.addressBar.restore.invalidate panel=\(id.uuidString.prefix(5)) " +
            "generation=\(addressBarFocusRestoreGeneration)"
        )
#endif
    }

    func restoreAddressBarPageFocusIfNeeded(completion: @escaping (Bool) -> Void) {
        addressBarFocusRestoreGeneration &+= 1
        let generation = addressBarFocusRestoreGeneration
        let delays: [TimeInterval] = [0.0, 0.03, 0.09, 0.2]
        restoreAddressBarPageFocusAttemptIfNeeded(
            attempt: 0,
            delays: delays,
            generation: generation,
            completion: completion
        )
    }

    private func restoreAddressBarPageFocusAttemptIfNeeded(
        attempt: Int,
        delays: [TimeInterval],
        generation: UInt64,
        completion: @escaping (Bool) -> Void
    ) {
        guard generation == addressBarFocusRestoreGeneration else {
            completion(false)
            return
        }
        webView.evaluateJavaScript(Self.addressBarFocusRestoreScript) { [weak self] result, error in
            guard let self else {
                completion(false)
                return
            }
            guard generation == self.addressBarFocusRestoreGeneration else {
                completion(false)
                return
            }

            let status = Self.addressBarPageFocusRestoreStatus(from: result, error: error)
            let canRetry = (status == .notFocused || status == .error)
            let hasNextAttempt = attempt + 1 < delays.count

#if DEBUG
            if let error {
                cmuxDebugLog(
                    "browser.focus.addressBar.restore panel=\(self.id.uuidString.prefix(5)) " +
                    "attempt=\(attempt) status=\(status.rawValue) " +
                    "message=\(error.localizedDescription)"
                )
            } else {
                cmuxDebugLog(
                    "browser.focus.addressBar.restore panel=\(self.id.uuidString.prefix(5)) " +
                    "attempt=\(attempt) status=\(status.rawValue)"
                )
            }
#endif

            if status == .restored {
                completion(true)
                return
            }

            if canRetry && hasNextAttempt {
                let delay = delays[attempt + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else {
                        completion(false)
                        return
                    }
                    guard generation == self.addressBarFocusRestoreGeneration else {
                        completion(false)
                        return
                    }
                    self.restoreAddressBarPageFocusAttemptIfNeeded(
                        attempt: attempt + 1,
                        delays: delays,
                        generation: generation,
                        completion: completion
                    )
                }
                return
            }

            completion(false)
        }
    }

    /// Returns the most reliable URL string for omnibar-related matching and UI decisions.
    /// `currentURL` can lag behind navigation changes, so prefer the live WKWebView URL.
    func preferredURLStringForOmnibar() -> String? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url)?.absoluteString
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

    private func resolvedCurrentSessionHistoryURL() -> URL? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url),
           Self.serializableSessionHistoryURLString(webViewURL) != nil {
            return webViewURL
        }
        if let currentURL,
           Self.serializableSessionHistoryURLString(currentURL) != nil {
            return currentURL
        }
        return restoredHistoryCurrentURL
    }

    private func refreshNavigationAvailability() {
        let resolvedCanGoBack: Bool
        let resolvedCanGoForward: Bool
        if usesRestoredSessionHistory {
            resolvedCanGoBack = nativeCanGoBack || !restoredBackHistoryStack.isEmpty
            resolvedCanGoForward = nativeCanGoForward || !restoredForwardHistoryStack.isEmpty
        } else {
            resolvedCanGoBack = nativeCanGoBack
            resolvedCanGoForward = nativeCanGoForward
        }

        if canGoBack != resolvedCanGoBack {
            canGoBack = resolvedCanGoBack
        }
        if canGoForward != resolvedCanGoForward {
            canGoForward = resolvedCanGoForward
        }
    }

    private func abandonRestoredSessionHistoryIfNeeded() {
        guard usesRestoredSessionHistory else { return }
        usesRestoredSessionHistory = false
        restoredBackHistoryStack.removeAll(keepingCapacity: false)
        restoredForwardHistoryStack.removeAll(keepingCapacity: false)
        restoredHistoryCurrentURL = nil
        refreshNavigationAvailability()
    }

    private static func serializableSessionHistoryURLString(_ url: URL?) -> String? {
        guard let url else { return nil }
        guard !isTemporarySessionHistoryURL(url) else { return nil }
        let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "about:blank" else { return nil }
        return value
    }

    private static func sanitizedSessionHistoryURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "about:blank" else { return nil }
        guard let url = URL(string: trimmed),
              !isTemporarySessionHistoryURL(url) else {
            return nil
        }
        return url
    }

    private static func sanitizedSessionHistoryURLs(_ values: [String]) -> [URL] {
        values.compactMap { sanitizedSessionHistoryURL($0) }
    }

    private static func isTemporarySessionHistoryURL(_ url: URL?) -> Bool {
        browserIsTemporaryHistoryURL(url)
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
            return browserFallbackInteractiveModalHostWindow()
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
                if cmuxIsWebInspectorObject(subview) {
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
    @discardableResult
    func applyPageZoom(_ candidate: CGFloat) -> Bool {
        let clamped = max(minPageZoom, min(maxPageZoom, candidate))
        if abs(webView.pageZoom - clamped) < 0.0001 {
            return false
        }
        webView.pageZoom = clamped
        return true
    }

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
        cmuxIsWebInspectorObject(view)
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

