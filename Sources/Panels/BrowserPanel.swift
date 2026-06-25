import Foundation
import Observation
import CmuxCore
import CmuxFoundation
import CmuxPanes
import CmuxBrowser
import CmuxSettings
import Combine
import CmuxAppKitSupportUI
import WebKit
import AppKit
import Bonsplit
import CmuxTerminalCore
import CmuxNotifications
import Network
import CFNetwork
import Darwin
import CmuxTerminal

// The browser focus-mode plain-Escape decision logic moved to
// `CmuxBrowser/Focus/BrowserFocusModeEscapeMachine.swift` as a pure value-type
// machine (with `BrowserFocusModePlainEscapeEventFingerprint`). This panel keeps
// the published mirrors, the eligibility check, and the focus mutations; it
// feeds state into the machine and applies the returned decision.

// `GhosttyBackgroundTheme` moved to `Sources/RightSidebarChromeStyle.swift` as a
// real instance resolver holding an injected default-background provider
// (the caseless static namespace is retired). Its pure clamp + composite math
// routes through `CmuxAppKitSupportUI.WindowAppearanceSnapshot`. It lives beside
// the other chrome-tinting style helpers in an already-wired app-target file so
// the relocation lands in the app compile without a new `cmux.xcodeproj`
// `project.pbxproj` source entry.

// The import-data hint presentation cluster (`BrowserImportHintVariant`,
// `BrowserImportHintBlankTabPlacement`, `BrowserImportHintSettingsStatus`,
// `BrowserImportHintPresentation`) and the persisted-settings accessor (now
// `BrowserImportHintRepository`, formerly the caseless `BrowserImportHintSettings`
// namespace) live in the `CmuxBrowser` package's `Import/Hint/` folder. The call
// sites below reference them through that import.

// `BrowserProfileDefinition` and `BrowserProfileClearOutcome` now live in the
// `CmuxBrowser` package (imported above); the call sites reference them
// unqualified through that import.

// `BrowserProfileStore` (the `@MainActor @Observable` facade over
// `BrowserProfileRepository`, vending profiles/lastUsedProfileID plus
// create/rename/delete/clear/noteUsed and the websiteDataStore/historyStore
// lookups), its three private adapters (`BrowserProfileHistoryAdapter`,
// `BrowserProfileWebsiteDataStoreAdapter`, `BrowserProfileFileRemover`), the
// `BrowserHistoryStore: BrowserProfileHistoryStore` conformance, and the
// `BrowserProfileStore: BrowserImportProfileResolving` conformance now live in
// the `CmuxBrowser` package's `Profiles/` folder (imported above). `static let
// shared` is kept (pure relocation, not de-singletonization). The built-in
// default profile's localized display name must stay app-side: it is resolved
// at the composition point and pushed into the package via
// `BrowserProfileStore.defaultProfileDisplayNameProvider` (see
// `bootstrapBrowserDefaultsIfNeeded()`), because in-package `String(localized:)`
// would bind to the package bundle and drop Japanese.

// `BrowserHistoryStore` (`@MainActor @Observable`, the history entries
// source-of-truth + didSet cache invalidation, load/record/suggest/merge/
// clear/remove/flush/scheduleSave, and the nonisolated location/default-URL
// resolvers) now lives in the `CmuxBrowser` package's `History/` folder
// (imported above) alongside its collaborators. `static let shared` is kept
// for now (pure relocation, not de-singletonization), so the call sites here
// resolve `BrowserHistoryStore` and `BrowserHistoryStore.Entry` through that
// import. The former app-side `uiTestSeedEntriesIfConfigured()` hook moved into
// the store as its default `uiTestSeedEntriesProvider`
// (`BrowserHistoryStore.uiTestSeedEntriesFromEnvironment()`), consulted by
// `loadIfNeeded()` inside the package.

/// BrowserPanel provides a WKWebView-based browser panel.
/// Each browser panel can recover from WebContent crashes by replacing its web view.
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

    /// The deadline-based omnibar/web-view focus suppression policy.
    ///
    /// Holds the two short-lived suppression deadlines (omnibar auto-focus and
    /// forced web-view focus) and owns the pure `Date() < until` decisions. The
    /// panel arms and clears the deadlines through the mutators below and reads
    /// the decisions through them; `#if DEBUG` logging stays app-side at those
    /// mutators. The address-bar suppression latch is app-side state (below) and
    /// is passed into the web-view decision rather than stored on the policy.
    private var focusSuppression = BrowserFocusSuppressionPolicy()
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

    /// The replayable back/forward session history this surface restores from a
    /// prior launch. The pure stack state machine lives in `CmuxBrowser`;
    /// this surface owns the instance, feeds it the resolved live current URL,
    /// and performs the `WKWebView` calls its decisions return. The temporary-URL
    /// classification (diff viewer + remote loopback proxy alias) is inverted into
    /// the injected sanitizer seam.
    private var restoredSessionHistory = RestoredSessionHistory(
        sanitizer: SessionHistoryURLSanitizer { CmuxDiffViewerURLSchemeHandler.isTemporaryHistoryURL($0) }
    )

    /// Sanitizer mirroring the restored-session-history URL rules, used by the
    /// surface's WebKit-touching resolution helpers.
    private let sessionHistoryURLSanitizer = SessionHistoryURLSanitizer {
        CmuxDiffViewerURLSchemeHandler.isTemporaryHistoryURL($0)
    }

    private var usesRestoredSessionHistory: Bool {
        restoredSessionHistory.usesRestoredSessionHistory
    }
    private var restoredHistoryCurrentURL: URL? {
        restoredSessionHistory.current
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

    /// The pure plain-Escape decision/arming state. This panel feeds its mirrors
    /// into the machine, applies the returned decision, and adopts the machine's
    /// next state. The machine owns the arm timestamp and last-fingerprint; the
    /// panel owns `isBrowserFocusModeActive`/`isBrowserFocusModeExitArmed` and the
    /// notifications.
    private var browserFocusModeEscapeMachine = BrowserFocusModeEscapeMachine()

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
                findNeedleDebounceCoordinator.observe(searchState)
            } else if let oldValue {
                lastSearchNeedle = oldValue.needle
                findNeedleDebounceCoordinator.stop()
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

    /// Debounces find-in-page needle edits and forwards each settled query to ``executeFindSearch(_:)``.
    /// Owns the policy the panel used to inline as a Combine pipeline on `BrowserSearchState.$needle`:
    /// it observes `needle` via `withObservationTracking` (so `BrowserSearchState` stays `@Observable`)
    /// and applies the same dedup + count>=3-immediate-else-300ms-delay policy via an injected,
    /// cancellable `Clock`. Seeded when `searchState` is created, torn down when it is cleared.
    private lazy var findNeedleDebounceCoordinator = BrowserFindNeedleDebounceCoordinator(
        onNeedle: { [weak self] needle in
            guard let self else { return }
#if DEBUG
            cmuxDebugLog("browser.find.needle.updated panel=\(self.id.uuidString.prefix(5)) bytes=\(needle.lengthOfBytes(using: .utf8))")
#endif
            self.executeFindSearch(needle)
        }
    )

    /// Find-in-page search execution: generates the find scripts, evaluates them against the
    /// panel's live `webView` through ``BrowserFindWebViewEvaluator``, and parses results into
    /// `BrowserFindMatchCount`. The panel owns the find bar visibility, focus, and `searchState`;
    /// this service owns only the script generation and result parsing.
    private lazy var findService = BrowserFindService(
        evaluator: BrowserFindWebViewEvaluator(panel: self)
    )
    let portalAnchorView = BrowserPortalAnchorView(frame: .zero)
    /// The portal-host lease decision logic, lifted to
    /// `CmuxBrowser/Panel/BrowserPortalHostLeaseMachine.swift` as a pure value
    /// type. The panel holds this instance, feeds it `(hostId, paneId, inWindow,
    /// bounds)` through the thin `claimPortalHost`/`releasePortalHostIfOwned`/
    /// `preparePortalHostReplacementForNextDistinctClaim` appliers below, adopts
    /// the returned machine state, and emits the requested DEBUG markers app-side.
    private var portalHostLeaseMachine = BrowserPortalHostLeaseMachine()
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

    /// Favicon discovery, fetch, decode, and validation for this panel's tab/sidebar
    /// icon. Owns the in-flight refresh task, refresh generation, and last-fetched
    /// icon URL; reaches the panel's live web view and remote-proxy state through
    /// ``BrowserFaviconWebViewEvaluator``. The panel owns the published
    /// `faviconPNGData` state and assigns it from the service's validated result.
    private lazy var faviconService = BrowserFaviconService(
        evaluator: BrowserFaviconWebViewEvaluator(panel: self)
    )
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

    /// Owns the WebKit Web Inspector (developer tools) subsystem.
    ///
    /// The coordinator (in `CmuxBrowser`) holds all inspector intent, presentation
    /// preference, and transition/retry machinery. It reaches this panel's live
    /// `webView` and the few app-side side effects through
    /// ``BrowserDeveloperToolsHostAdapter``, which holds the panel weakly so the
    /// panel and coordinator do not retain each other. The panel keeps its
    /// `@Published preferredDeveloperToolsVisible` as the observable mirror; the
    /// coordinator is its only writer via the host setter.
    private lazy var developerToolsCoordinator = BrowserDeveloperToolsCoordinator(
        host: BrowserDeveloperToolsHostAdapter(panel: self),
        logSink: Self.developerToolsLogSink
    )
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
        BrowserWebViewLifecycleTelemetry(
            state: webViewLifecycleState.rawValue,
            isVisibleInUI: isWebViewVisibleInUI,
            shouldRenderWebView: shouldRenderWebView,
            discardBlockers: hiddenWebViewDiscardBlockers(),
            discardedAt: hiddenWebViewDiscardManager.discardedAt,
            lastDiscardReason: hiddenWebViewDiscardManager.lastDiscardReason,
            lastRestoreReason: hiddenWebViewDiscardManager.lastRestoreReason,
            lastVisibleAt: webViewLastVisibleAt,
            lastHiddenAt: webViewLastHiddenAt,
            lastVisibilityChangeAt: webViewLastVisibilityChangeAt,
            lastVisibilityChangeReason: webViewLastVisibilityChangeReason,
            now: now
        ).payload()
    }

    private func refreshWebViewLifecycleState() {
        let nextState = BrowserWebViewLifecycleState.resolve(
            isClosing: isClosingWebViewLifecycle,
            isDiscardedForMemory: hiddenWebViewDiscardManager.isDiscardedForMemory,
            shouldRenderWebView: shouldRenderWebView,
            hasPreferredURL: preferredURLStringForOmnibar() != nil,
            isVisibleInUI: isWebViewVisibleInUI
        )
        guard webViewLifecycleState != nextState else { return }
        webViewLifecycleState = nextState
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
        faviconService.cancel()
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
        portalHostLeaseMachine = portalHostLeaseMachine.cleared()

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

    /// Re-arms a one-shot force-distinct portal-host replacement for the next claim
    /// in `paneId`. Thin applier over ``BrowserPortalHostLeaseMachine``: feeds the
    /// machine, adopts its next state, and emits the DEBUG marker app-side.
    func preparePortalHostReplacementForNextDistinctClaim(
        inPane paneId: PaneID,
        reason: String
    ) {
        let outcome = portalHostLeaseMachine.prepareReplacementForNextDistinctClaim(inPane: paneId)
        portalHostLeaseMachine = outcome.machine
        emitPortalHostLeaseDebugEvents(outcome.debugEvents, reason: reason)
    }

    /// Claims (or keeps) the portal host for `paneId`. Thin applier over
    /// ``BrowserPortalHostLeaseMachine``: gates inline developer-tools hosting
    /// app-side, feeds the machine, adopts its next state, emits the DEBUG markers,
    /// and returns the machine's verdict.
    func claimPortalHost(
        hostId: ObjectIdentifier,
        paneId: PaneID,
        inWindow: Bool,
        bounds: CGRect,
        reason: String
    ) -> Bool {
        let outcome = portalHostLeaseMachine.claim(
            hostId: hostId,
            paneId: paneId,
            inWindow: inWindow,
            bounds: bounds,
            usesLocalInlineDeveloperToolsHosting: shouldUseLocalInlineDeveloperToolsHosting()
        )
        portalHostLeaseMachine = outcome.machine
        emitPortalHostLeaseDebugEvents(outcome.debugEvents, reason: reason)
        return outcome.claimed
    }

    /// Releases the portal host when this panel's lease is owned by `hostId`. Thin
    /// applier over ``BrowserPortalHostLeaseMachine``.
    @discardableResult
    func releasePortalHostIfOwned(hostId: ObjectIdentifier, reason: String) -> Bool {
        let outcome = portalHostLeaseMachine.release(hostId: hostId)
        portalHostLeaseMachine = outcome.machine
        emitPortalHostLeaseDebugEvents(outcome.debugEvents, reason: reason)
        return outcome.released
    }

    /// Emits the `#if DEBUG` `cmuxDebugLog` markers the lease machine requested,
    /// reproducing the legacy log lines one-for-one (the panel owns the `panel=…`
    /// prefix and the `reason=…` suffix the machine cannot see).
    private func emitPortalHostLeaseDebugEvents(
        _ events: [BrowserPortalHostLeaseMachine.DebugEvent],
        reason: String
    ) {
#if DEBUG
        let panelPrefix = id.uuidString.prefix(5)
        for event in events {
            switch event {
            case let .rearm(paneId):
                cmuxDebugLog(
                    "browser.portal.host.rearm panel=\(panelPrefix) " +
                    "reason=\(reason) pane=\(paneId.uuidString.prefix(5))"
                )
            case let .skipLocalInlineDevTools(host, paneId, inWindow, bounds):
                cmuxDebugLog(
                    "browser.portal.host.skip panel=\(panelPrefix) " +
                    "reason=\(reason).localInlineDevTools host=\(host) pane=\(paneId.uuidString.prefix(5)) " +
                    "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
                )
            case let .claimReplacing(host, paneId, inWindow, bounds, replacing, forced):
                cmuxDebugLog(
                    "browser.portal.host.claim panel=\(panelPrefix) " +
                    "reason=\(reason) host=\(host) pane=\(paneId.uuidString.prefix(5)) " +
                    "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                    "replacingHost=\(replacing.hostId) replacingPane=\(replacing.paneId.uuidString.prefix(5)) " +
                    "replacingInWin=\(replacing.inWindow ? 1 : 0) replacingArea=\(String(format: "%.1f", replacing.area))" +
                    (forced ? " forced=1" : "")
                )
            case let .skipOwner(host, paneId, inWindow, bounds, owner, locked):
                cmuxDebugLog(
                    "browser.portal.host.skip panel=\(panelPrefix) " +
                    "reason=\(reason) host=\(host) pane=\(paneId.uuidString.prefix(5)) " +
                    "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                    "ownerHost=\(owner.hostId) ownerPane=\(owner.paneId.uuidString.prefix(5)) " +
                    "ownerInWin=\(owner.inWindow ? 1 : 0) ownerArea=\(String(format: "%.1f", owner.area)) " +
                    "locked=\(locked ? 1 : 0)"
                )
            case let .claimFresh(host, paneId, inWindow, bounds):
                cmuxDebugLog(
                    "browser.portal.host.claim panel=\(panelPrefix) " +
                    "reason=\(reason) host=\(host) pane=\(paneId.uuidString.prefix(5)) " +
                    "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                    "replacingHost=nil"
                )
            case let .release(host, released):
                cmuxDebugLog(
                    "browser.portal.host.release panel=\(panelPrefix) " +
                    "reason=\(reason) host=\(host) pane=\(released.paneId.uuidString.prefix(5)) " +
                    "inWin=\(released.inWindow ? 1 : 0) area=\(String(format: "%.1f", released.area))"
                )
            }
        }
#else
        _ = events
        _ = reason
#endif
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
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.appDefault.currentColor()
        // Always present as Safari.
        webView.customUserAgent = BrowserUserAgent.safari
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
                source: BrowserTelemetryHookBootstrapScript.consoleAndErrorSource,
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
                source: BrowserOmnibarPageFocusRepository.trackingBootstrapScriptSource,
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
                self.faviconService.clearLastFetchedIconURL()
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
    /// Tests exercise ``CmuxBrowser/BrowserDefaultsNormalizer`` directly with a
    /// scratch suite instead.
    static func bootstrapBrowserDefaultsIfNeeded() {
        guard !hasBootstrappedBrowserDefaults else { return }
        hasBootstrappedBrowserDefaults = true
        installLocalizedDefaultProfileName()
        BrowserDefaultsNormalizer().normalize(defaults: .standard)
    }

    /// Pushes the app-bundle-resolved default profile name into `CmuxBrowser`'s
    /// `BrowserProfileStore` before its `shared` singleton seeds. Resolving
    /// `String(localized:)` here (app target) keeps the Japanese translation,
    /// which an in-package resolution would drop by binding to the package bundle.
    ///
    /// TODO(refactor): the composition root (`AppDelegate.applicationDidFinishLaunching`)
    /// should call this before any `BrowserProfileStore.shared` access so the
    /// localized name is in place even when a Workspace/TerminalController/
    /// BrowserAutomation path touches `shared` before the first `BrowserPanel`.
    static func installLocalizedDefaultProfileName() {
        BrowserProfileStore.defaultProfileDisplayNameProvider = {
            String(localized: "browser.profile.default", defaultValue: "Default")
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
        self.insecureHTTPBypassHostOnce = RemoteLoopbackProxyAlias.normalizeHost(bypassInsecureHTTPHostOnce ?? "")
        self.bypassesRemoteWorkspaceProxy = bypassRemoteProxy
        self.remoteProxyEndpoint = bypassRemoteProxy ? nil : proxyEndpoint
        self.usesRemoteWorkspaceProxy = isRemoteWorkspace && !bypassRemoteProxy
        self.browserThemeMode = BrowserThemeMode.mode()
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
        applyProxyConfigurationIfAvailable()
        BrowserProfileStore.shared.noteUsed(resolvedProfileID)

        // Set up navigation delegate.
        // TODO(refactor): `externalNavigationPresenter` and `hasRecentMiddleClickIntent(for:)`
        // are owned by the concurrent external-navigation move; the presenter built with
        // app-resolved `BrowserExternalNavigationStrings` and the `CmuxWebView`-backed
        // middle-click probe are injected here once that move lands.
        let navDelegate = BrowserNavigationDelegate(
            externalNavigationPresenter: externalNavigationPresenter,
            hasRecentMiddleClickIntent: { webView in CmuxWebView.hasRecentMiddleClickIntent(for: webView) }
        )
        navDelegate.logSink = Self.navigationLogSink
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
        dlDelegate.logSink = Self.downloadLogSink
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

        // Set up UI delegate (handles cmd+click, target=_blank, and context menu).
        // See the navigation-delegate TODO above: `externalNavigationPresenter` and the
        // `CmuxWebView`-backed middle-click probe come from the concurrent
        // external-navigation move.
        let browserUIDelegate = BrowserUIDelegate(
            externalNavigationPresenter: externalNavigationPresenter,
            hasRecentMiddleClickIntent: { webView in CmuxWebView.hasRecentMiddleClickIntent(for: webView) }
        )
        browserUIDelegate.logSink = Self.navigationLogSink
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
        // Force the developer-tools coordinator to instantiate here so its
        // detached-inspector-window close observer installs at the same point in
        // panel init that the former inline observer install ran.
        _ = developerToolsCoordinator
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
        let desiredZoom = max(minPageZoom, min(maxPageZoom, previousWebView.pageZoom))
        let restoreDeveloperTools = preferredDeveloperToolsVisible || isDeveloperToolsVisible()

        invalidateSearchFocusRequests(reason: "profileSwitch")
        searchState = nil

        _ = hideDeveloperTools()
        developerToolsCoordinator.cancelDeveloperToolsRestoreRetry()

        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        clearWebContentTerminationRecovery()
        clearBrowserFocusMode(reason: "profileSwitch")
        faviconService.cancel()
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
        guard NotificationPaneFlashSettings().isEnabled else { return }
        focusFlashToken &+= 1
    }

    func sessionNavigationHistorySnapshot() -> (
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String]
    ) {
        realignRestoredSessionHistoryToLiveCurrentIfPossible()

        let snapshot = restoredSessionHistory.snapshot(
            nativeBackURLs: webView.backForwardList.backList.map { $0.url },
            nativeForwardURLs: webView.backForwardList.forwardList.map { $0.url },
            isLiveAligned: isLiveSessionHistoryAlignedWithRestoredCurrent
        )
        return (snapshot.backHistoryURLStrings, snapshot.forwardHistoryURLStrings)
    }

    private func resolvedLiveSessionHistoryURL() -> URL? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url),
           sessionHistoryURLSanitizer.serializableSessionHistoryURLString(webViewURL) != nil {
            return webViewURL
        }
        if let currentURL,
           sessionHistoryURLSanitizer.serializableSessionHistoryURLString(currentURL) != nil {
            return currentURL
        }
        return nil
    }

    private var isLiveSessionHistoryAlignedWithRestoredCurrent: Bool {
        restoredSessionHistory.isLiveAligned(withLiveCurrentURL: resolvedLiveSessionHistoryURL())
    }

    private func realignRestoredSessionHistoryToLiveCurrentIfPossible() {
        switch restoredSessionHistory.realign(toLiveCurrentURL: resolvedLiveSessionHistoryURL()) {
        case .noChange:
            return
        case .rebalanced:
            refreshNavigationAvailability()
        case .clearedForward(let liveCurrentString):
#if DEBUG
            cmuxDebugLog(
                "browser.history.restore.forward.clear panel=\(id.uuidString.prefix(5)) " +
                "current=\(liveCurrentString)"
            )
#endif
            refreshNavigationAvailability()
        }
    }

    func restoreSessionNavigationHistory(
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String],
        currentURLString: String?
    ) {
        let activated = restoredSessionHistory.restore(
            backHistoryURLStrings: backHistoryURLStrings,
            forwardHistoryURLStrings: forwardHistoryURLStrings,
            currentURLString: currentURLString
        )
        guard activated else { return }
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

        let restoredURL = sessionHistoryURLSanitizer.sanitizedSessionHistoryURL(snapshot.urlString)
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
        guard !sessionHistoryURLSanitizer.isTemporarySessionHistoryURL(webView.url),
              !sessionHistoryURLSanitizer.isTemporarySessionHistoryURL(currentURL),
              !sessionHistoryURLSanitizer.isTemporarySessionHistoryURL(restoredHistoryCurrentURL) else {
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
           let value = sessionHistoryURLSanitizer.serializableSessionHistoryURLString(webViewURL) {
            return value
        }
        if let currentURL,
           let value = sessionHistoryURLSanitizer.serializableSessionHistoryURLString(currentURL) {
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
                self.applyWebViewBackground(color: GhosttyBackgroundTheme.appDefault.color(from: notification))
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
        applyWebViewBackground(color: GhosttyBackgroundTheme.appDefault.currentColor())
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
    /// backdrop. Mirrors terminal/markdown panel background decisions. Reads the
    /// app-coupled engine runtime + window composition policy, then forwards the
    /// resolved inputs into `BrowserWebViewBackgroundDrawPolicy` (CmuxBrowser).
    static func drawsConfiguredWebViewBackground(
        isBlankPage: Bool,
        usesTransparentBackground: Bool = false
    ) -> Bool {
        BrowserWebViewBackgroundDrawPolicy().drawsWebViewBackground(
            isBlankPage: isBlankPage,
            usesTransparentBackground: usesTransparentBackground,
            opacity: GhosttyApp.shared.engineRuntime.defaultBackgroundOpacity,
            usesGhosttyGlassStyle: GhosttyApp.shared.engineRuntime.defaultBackgroundBlur.isMacOSGlassStyle,
            usesTransparentWindow: WindowBackgroundComposition.policy
                .shouldUseTransparentBackgroundWindow(glassEffectAvailable: false)
        )
    }

    nonisolated static func isBlankBrowserPageURL(_ url: URL?) -> Bool {
        BrowserBlankPageClassifier().isBlankBrowserPageURL(url)
    }

    nonisolated static func isBlankBrowserPage(
        liveURL: URL?,
        currentURL: URL?,
        pendingNavigationURL: URL?,
        isMainFrameProvisionalNavigationActive: Bool
    ) -> Bool {
        BrowserBlankPageClassifier().isBlankBrowserPage(
            liveURL: liveURL,
            currentURL: currentURL,
            pendingNavigationURL: pendingNavigationURL,
            isMainFrameProvisionalNavigationActive: isMainFrameProvisionalNavigationActive
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
        faviconService.cancel()
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
            let urlString = Self.remoteProxyDisplayURL(for: webView.url)?.absoluteString ?? currentURL?.absoluteString
            if urlString == nil || urlString == "about:blank" {
                return
            }
        }

        if window.firstResponder?.responderChain(contains: webView) ?? false {
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

        if window.firstResponder?.responderChain(contains: webView) ?? false {
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
            if !(window.firstResponder?.responderChain(contains: webView) ?? false),
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
        if window.firstResponder?.responderChain(contains: webView) ?? false {
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
        faviconService.cancel()
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

    /// Drives ``BrowserFaviconService`` for the panel's current page and publishes
    /// the validated PNG into `faviconPNGData`.
    ///
    /// The service owns the discovery/fetch/decode flow, the in-flight task, and
    /// the dedup state; this forwarder only supplies the committed page URL plus
    /// the live web-view identity and reads/writes the panel's published
    /// `faviconPNGData`.
    private func refreshFavicon(from webView: WKWebView) {
        guard let pageURL = webView.url else {
            faviconService.cancel()
            return
        }
        faviconService.refresh(
            pageURL: pageURL,
            webViewInstanceID: webViewInstanceID,
            panelIDPrefix: String(id.uuidString.prefix(5)),
            currentFaviconPNGData: { [weak self] in self?.faviconPNGData },
            assignFaviconPNGData: { [weak self] png in self?.faviconPNGData = png }
        )
    }

    private func handleWebViewLoadingChanged(_ newValue: Bool) {
        if newValue {
            cancelHiddenWebViewDiscard()
            // Any new load invalidates older favicon fetches, even for same-URL reloads.
            faviconService.resetForNewLoad()
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
        preserveRestoredSessionHistory: Bool = false,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) {
        let request = URLRequest(url: url, cachePolicy: cachePolicy)
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
        // Resume on endpoint arrival, or directly once the pane turned local
        // (a stranded queue pins the hidden pane as non-discardable forever).
        guard remoteProxyEndpoint != nil || !usesRemoteWorkspaceProxy,
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
        webView.customUserAgent = BrowserUserAgent.safari
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

    /// The panel's active remote-workspace proxy endpoint, or `nil` when the panel
    /// is not bound to a remote workspace. Read by ``BrowserFaviconWebViewEvaluator``
    /// so the favicon fetch tunnels through the same proxy as page navigations.
    var activeRemoteProxyEndpoint: BrowserProxyEndpoint? {
        remoteProxyEndpoint
    }

    func remoteProxyPreparedRequest(from request: URLRequest, logScope: String) -> URLRequest {
        guard remoteProxyEndpoint != nil else { return request }
        guard let url = request.url else { return request }
        guard let rewrittenURL = BrowserRemoteProxyURLResolver().loopbackAliasURL(for: url) else { return request }

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

    /// Thin forwarder to ``BrowserRemoteProxyURLResolver/displayURL(for:)`` (moved
    /// into CmuxBrowser/Navigation). Keeps the existing `Self.remoteProxyDisplayURL(_:)`
    /// call sites stable.
    private static func remoteProxyDisplayURL(for url: URL?) -> URL? {
        BrowserRemoteProxyURLResolver().displayURL(for: url)
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

        let searchConfiguration = BrowserSearchSettingsStore().currentConfiguration
        guard let searchURL = searchConfiguration.searchURL(query: trimmed) else { return }
        navigate(to: searchURL)
    }

    func resolveNavigableURL(from input: String) -> URL? {
        BrowserNavigableURLResolver().resolve(input)
    }

    private func shouldBlockInsecureHTTPNavigation(to url: URL) -> Bool {
        if consumeOneTimeInsecureHTTPBypassIfNeeded(for: url) {
            return false
        }
        return BrowserInsecureHTTPRepository().shouldBlock(url)
    }

    @discardableResult
    private func consumeOneTimeInsecureHTTPBypassIfNeeded(for url: URL) -> Bool {
        BrowserInsecureHTTPRepository().consumeOneTimeBypass(url, bypassHostOnce: &insecureHTTPBypassHostOnce)
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
        guard let host = RemoteLoopbackProxyAlias.normalizeHost(url.host ?? "") else { return }

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
        let insecureHTTPRepository = BrowserInsecureHTTPRepository()
        if insecureHTTPRepository.shouldPersistAllowlistSelection(
            response: response,
            suppressionEnabled: alert?.suppressionButton?.state == .on
        ) {
            insecureHTTPRepository.addAllowedHost(host)
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
        restoredSessionHistory.hasRestoredState ||
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

        clearBrowserFocusMode(reason: "contextReset")
        developerToolsCoordinator.resetForWorkspaceContextChange()
        clearWebContentTerminationRecovery()

        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil
        faviconService.resetForNewLoad()
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
        focusSuppression.omnibarAutofocusUntil = nil
        focusSuppression.webViewFocusUntil = nil
        endSuppressWebViewFocusForAddressBar()
        invalidateAddressBarPageFocusRestoreAttempts()
        invalidateSearchFocusRequests(reason: "contextReset")
        searchState = nil

        pageTitle = ""
        currentURL = nil
        hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
        faviconPNGData = nil
        resetWebViewLifecycleMetadata()
        portalHostLeaseMachine = portalHostLeaseMachine.cleared()

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

            let decision = restoredSessionHistory.decideGoBack(
                isLiveAligned: isLiveSessionHistoryAlignedWithRestoredCurrent,
                nativeCanGoBack: nativeCanGoBack,
                resolvedCurrentURL: resolvedCurrentSessionHistoryURL()
            )
            switch decision {
            case .navigate(let targetURL):
                refreshNavigationAvailability()
                navigateWithoutInsecureHTTPPrompt(
                    to: targetURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: true
                )
            case .nativeGoBack:
                webView.goBack()
            case .nativeGoForward, .refreshOnly:
                refreshNavigationAvailability()
            }
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

            let decision = restoredSessionHistory.decideGoForward(
                nativeCanGoForward: nativeCanGoForward,
                resolvedCurrentURL: resolvedCurrentSessionHistoryURL()
            )
            switch decision {
            case .nativeGoForward:
                webView.goForward()
            case .navigate(let targetURL):
                refreshNavigationAvailability()
                navigateWithoutInsecureHTTPPrompt(
                    to: targetURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: true
                )
            case .nativeGoBack, .refreshOnly:
                refreshNavigationAvailability()
            }
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
        guard let seed = BrowserNewTabNavigationSeed(
            request: request,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        ) else {
            return
        }
#if DEBUG
        cmuxDebugLog(
            "browser.newTab.open.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) url=\(BrowserPopupNavigationPolicy().debugURL(seed.url)) " +
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

    private func prepareForReload(reason: String, mode: BrowserPanelReloadMode) -> Bool {
        if recoverTerminatedWebContent(reason: reason, cachePolicy: mode.recoveryCachePolicy) {
            return true
        }
        if restoreDiscardedWebViewIfNeeded(reason: reason, cachePolicy: mode.recoveryCachePolicy) {
            return true
        }
        webView.customUserAgent = BrowserUserAgent.safari
        if sessionHistoryURLSanitizer.serializableSessionHistoryURLString(Self.remoteProxyDisplayURL(for: webView.url)) == nil {
            let fallbackURL = resolvedCurrentSessionHistoryURL()
                ?? Self.remoteProxyDisplayURL(for: navigationDelegate?.lastAttemptedURL)

            if let fallbackURL,
               sessionHistoryURLSanitizer.serializableSessionHistoryURLString(fallbackURL) != nil {
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

    // MARK: - Developer tools (forwards to BrowserDeveloperToolsCoordinator)

    @discardableResult
    func closeDeveloperToolsFromDetachedInspectorWindowUserAction(
        _ window: NSWindow,
        source: String
    ) -> Bool {
        developerToolsCoordinator.closeDeveloperToolsFromDetachedInspectorWindowUserAction(window, source: source)
    }

    @discardableResult
    func toggleDeveloperTools() -> Bool {
        developerToolsCoordinator.toggleDeveloperTools()
    }

    @discardableResult
    func showDeveloperTools() -> Bool {
        developerToolsCoordinator.showDeveloperTools()
    }

    @discardableResult
    func showDeveloperToolsConsole() -> Bool {
        developerToolsCoordinator.showDeveloperToolsConsole()
    }

    @discardableResult
    func closeDeveloperToolsForTeardown() -> Bool {
        developerToolsCoordinator.closeDeveloperToolsForTeardown()
    }

    /// Called before WKWebView detaches so manual inspector closes are respected.
    func syncDeveloperToolsPreferenceFromInspector(preserveVisibleIntent: Bool = false) {
        developerToolsCoordinator.syncDeveloperToolsPreferenceFromInspector(preserveVisibleIntent: preserveVisibleIntent)
    }

    func noteDeveloperToolsHostAttached() {
        developerToolsCoordinator.noteDeveloperToolsHostAttached()
    }

    func scheduleDeveloperToolsVisibilityLossCheck() {
        developerToolsCoordinator.scheduleDeveloperToolsVisibilityLossCheck()
    }

    func cancelPendingDeveloperToolsVisibilityLossCheck() {
        developerToolsCoordinator.cancelPendingDeveloperToolsVisibilityLossCheck()
    }

    @discardableResult
    func consumeAttachedDeveloperToolsManualCloseIfNeeded(inspector: NSObject? = nil) -> Bool {
        developerToolsCoordinator.consumeAttachedDeveloperToolsManualCloseIfNeeded(inspector: inspector)
    }

    /// Called after WKWebView reattaches to keep inspector stable across split/layout churn.
    func restoreDeveloperToolsAfterAttachIfNeeded() {
        developerToolsCoordinator.restoreDeveloperToolsAfterAttachIfNeeded()
    }

    @discardableResult
    func isDeveloperToolsVisible() -> Bool {
        developerToolsCoordinator.isDeveloperToolsVisible()
    }

    @discardableResult
    func hideDeveloperTools() -> Bool {
        developerToolsCoordinator.hideDeveloperTools()
    }

    /// During split/layout transitions SwiftUI can briefly mark the browser surface hidden
    /// while its container is off-window. Avoid detaching in that transient phase if
    /// DevTools is intended to remain open, because detach/reattach can blank inspector content.
    func shouldPreserveWebViewAttachmentDuringTransientHide() -> Bool {
        developerToolsCoordinator.shouldPreserveWebViewAttachmentDuringTransientHide()
    }

    func requestDeveloperToolsRefreshAfterNextAttach(reason: String) {
        developerToolsCoordinator.requestDeveloperToolsRefreshAfterNextAttach(reason: reason)
    }

    func hasPendingDeveloperToolsRefreshAfterAttach() -> Bool {
        developerToolsCoordinator.hasPendingDeveloperToolsRefreshAfterAttach()
    }

    func shouldPreserveDeveloperToolsIntentWhileDetached() -> Bool {
        developerToolsCoordinator.shouldPreserveDeveloperToolsIntentWhileDetached()
    }

    func shouldUseLocalInlineDeveloperToolsHosting() -> Bool {
        developerToolsCoordinator.shouldUseLocalInlineDeveloperToolsHosting()
    }

    func recordPreferredAttachedDeveloperToolsWidth(_ width: CGFloat, containerBounds: NSRect) {
        developerToolsCoordinator.recordPreferredAttachedDeveloperToolsWidth(width, containerBounds: containerBounds)
    }

    func preferredAttachedDeveloperToolsWidthState() -> (width: CGFloat?, widthFraction: CGFloat?) {
        developerToolsCoordinator.preferredAttachedDeveloperToolsWidthState()
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
            self.applyFindMatchCount(await self.findService.next())
        }
    }

    func findPrevious() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyFindMatchCount(await self.findService.previous())
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
            browserFocusModeEscapeMachine.hasArmingState
        else { return }
        browserFocusModeEscapeMachine = browserFocusModeEscapeMachine.cleared()
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
        browserFocusModeEscapeMachine = browserFocusModeEscapeMachine.cleared()
    }

    func clearBrowserFocusModeExitArm(reason: String) {
        guard isBrowserFocusModeExitArmed || browserFocusModeEscapeMachine.hasArmedExitTimestamp else { return }
        browserFocusModeEscapeMachine = browserFocusModeEscapeMachine.disarmedExitTimestamp()
        isBrowserFocusModeExitArmed = false
#if DEBUG
        cmuxDebugLog("browser.focusMode.escape.disarm panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
    }

    func handleBrowserFocusModeKeyEvent(_ event: NSEvent, reason: String) -> BrowserFocusModeKeyDecision {
        guard canEnterBrowserFocusMode else {
            clearBrowserFocusMode(reason: "\(reason).ineligible")
            return .inactive
        }

        let outcome = browserFocusModeEscapeMachine.decide(
            event: event,
            isActive: isBrowserFocusModeActive,
            isExitArmed: isBrowserFocusModeExitArmed
        )
        applyBrowserFocusModeEscapeOutcome(outcome, reason: reason)
        return outcome.decision
    }

    /// Adopts the machine's next state, sets the exit-armed mirror, performs the
    /// requested panel clears, and emits the requested DEBUG markers, faithfully
    /// reproducing the side-effect order of the legacy `handleBrowserFocusModeKeyEvent`.
    private func applyBrowserFocusModeEscapeOutcome(
        _ outcome: BrowserFocusModeEscapeMachine.Outcome,
        reason: String
    ) {
        // Adopt the machine's authoritative next state (arm timestamp +
        // fingerprint), then arm the published mirror on the arm/re-arm paths
        // exactly as the legacy handler did before logging its marker.
        browserFocusModeEscapeMachine = outcome.machine
        if outcome.armsExit {
            isBrowserFocusModeExitArmed = true
        }

        for clear in outcome.clears {
            switch clear {
            case let .focusMode(reasonSuffix):
                clearBrowserFocusMode(reason: "\(reason)\(reasonSuffix)")
            case let .escapeArms(reasonSuffix):
                clearBrowserFocusModeEscapeArms(reason: "\(reason)\(reasonSuffix)")
            }
        }

#if DEBUG
        for marker in outcome.debugMarkers {
            cmuxDebugLog("\(marker.logEvent) panel=\(id.uuidString.prefix(5)) reason=\(reason)")
        }
#endif
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
            self.applyFindMatchCount(await self.findService.search(needle: needle))
        }
    }

    private func executeFindClear() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.findService.clear()
        }
    }

    private func applyFindMatchCount(_ count: BrowserFindMatchCount?) {
        guard let count else { return }
        searchState?.total = count.total
        searchState?.selected = count.selected
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
        focusSuppression.omnibarAutofocusUntil = Date().addingTimeInterval(seconds)
#if DEBUG
        cmuxDebugLog(
            "browser.focus.omnibarAutofocus.suppress panel=\(id.uuidString.prefix(5)) " +
            "seconds=\(String(format: "%.2f", seconds))"
        )
#endif
    }

    func suppressWebViewFocus(for seconds: TimeInterval) {
        focusSuppression.webViewFocusUntil = Date().addingTimeInterval(seconds)
#if DEBUG
        cmuxDebugLog(
            "browser.focus.webView.suppress panel=\(id.uuidString.prefix(5)) " +
            "seconds=\(String(format: "%.2f", seconds))"
        )
#endif
    }

    func clearWebViewFocusSuppression() {
        focusSuppression.webViewFocusUntil = nil
#if DEBUG
        cmuxDebugLog("browser.focus.webView.suppress.clear panel=\(id.uuidString.prefix(5))")
#endif
    }

    func shouldSuppressOmnibarAutofocus() -> Bool {
        focusSuppression.shouldSuppressOmnibarAutofocus(now: Date())
    }

    func shouldSuppressWebViewFocus() -> Bool {
        focusSuppression.shouldSuppressWebViewFocus(
            addressBarSuppressed: suppressWebViewFocusForAddressBar,
            searchActive: searchState != nil,
            now: Date()
        )
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
           window.firstResponder?.responderChain(contains: webView) ?? false {
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

        if responder.responderChain(contains: webView) {
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
            guard window.firstResponder?.responderChain(contains: webView) ?? false else { return false }
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
           sessionHistoryURLSanitizer.serializableSessionHistoryURLString(webViewURL) != nil {
            return webViewURL
        }
        if let currentURL,
           sessionHistoryURLSanitizer.serializableSessionHistoryURLString(currentURL) != nil {
            return currentURL
        }
        return restoredHistoryCurrentURL
    }

    private func refreshNavigationAvailability() {
        let availability = restoredSessionHistory.availability(
            nativeCanGoBack: nativeCanGoBack,
            nativeCanGoForward: nativeCanGoForward
        )

        if canGoBack != availability.canGoBack {
            canGoBack = availability.canGoBack
        }
        if canGoForward != availability.canGoForward {
            canGoForward = availability.canGoForward
        }
    }

    private func abandonRestoredSessionHistoryIfNeeded() {
        guard restoredSessionHistory.abandon() else { return }
        refreshNavigationAvailability()
    }

}

private extension BrowserPanel {
    func applyBrowserThemeModeIfNeeded() {
        browserThemeMode.apply(to: webView)
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

    /// Debug-log sink handed to `BrowserDownloadDelegate`.
    ///
    /// In release builds this is `nil`, so the delegate emits no logging and the
    /// former `#if DEBUG`-guarded `cmuxDebugLog` download traces stay compiled out.
    static var downloadLogSink: (@Sendable (String) -> Void)? {
#if DEBUG
        return { message in cmuxDebugLog(message) }
#else
        return nil
#endif
    }

    /// Debug-log sink handed to `BrowserNavigationDelegate`/`BrowserUIDelegate`.
    ///
    /// In release builds this is `nil`, so the delegates emit no logging and the
    /// former `#if DEBUG`-guarded `cmuxDebugLog` navigation traces stay compiled
    /// out.
    static var navigationLogSink: (@MainActor @Sendable (String) -> Void)? {
#if DEBUG
        return { message in cmuxDebugLog(message) }
#else
        return nil
#endif
    }

    /// Debug-log sink handed to `BrowserDeveloperToolsCoordinator`.
    ///
    /// In release builds this is `nil`, so the coordinator emits no logging and the
    /// former `#if DEBUG`-guarded `cmuxDebugLog` developer-tools traces stay
    /// compiled out.
    static var developerToolsLogSink: (@MainActor @Sendable (String) -> Void)? {
#if DEBUG
        return { message in cmuxDebugLog(message) }
#else
        return nil
#endif
    }
}

extension BrowserPanel {
    /// File-private seam helpers the developer-tools host adapter forwards to.
    /// They expose the panel's `private` published mirror, hidden-discard
    /// scheduler, and observation nudge to a separate top-level type without
    /// widening the panel's public surface.
    fileprivate func setPreferredDeveloperToolsVisibleMirror(_ visible: Bool) {
        guard preferredDeveloperToolsVisible != visible else { return }
        preferredDeveloperToolsVisible = visible
    }

    fileprivate func forwardReevaluateHiddenWebViewDiscardScheduling(reason: String) {
        reevaluateHiddenWebViewDiscardScheduling(reason: reason)
    }

    fileprivate func notifyDeveloperToolsPresentationPreferenceDidChange() {
        objectWillChange.send()
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

/// Bridges `BrowserDeveloperToolsCoordinator` to a panel's live `WKWebView` and
/// the few app-side side effects the Web Inspector subsystem needs.
///
/// Holds the panel weakly so the panel (which owns the coordinator, which owns
/// this adapter) does not form a retain cycle. Always reads `panel.webView` at
/// call time because the panel reassigns its web view across navigations and
/// profile switches.
@MainActor
private final class BrowserDeveloperToolsHostAdapter: BrowserDeveloperToolsHosting {
    private weak var panel: BrowserPanel?

    init(panel: BrowserPanel) {
        self.panel = panel
    }

    var developerToolsWebView: WKWebView? {
        panel?.webView
    }

    var developerToolsPanelDebugID: String {
        guard let panel else { return "nil" }
        return String(panel.id.uuidString.prefix(5))
    }

    var developerToolsApplicationWindows: [NSWindow] {
        NSApp.windows
    }

    func setPreferredDeveloperToolsVisible(_ visible: Bool) {
        panel?.setPreferredDeveloperToolsVisibleMirror(visible)
    }

    func reevaluateHiddenWebViewDiscardScheduling(reason: String) {
        panel?.forwardReevaluateHiddenWebViewDiscardScheduling(reason: reason)
    }

    func developerToolsPresentationPreferenceDidChange() {
        panel?.notifyDeveloperToolsPresentationPreferenceDidChange()
    }

    func withBrowserFirstResponderBypass(_ body: () -> Void) {
        // Faithful to the former call site: when no AppDelegate is present the
        // optional-chained `withBypass` was never invoked, so the body did not run.
        AppDelegate.shared?.browserFirstResponderBypass.withBypass(body)
    }
}
