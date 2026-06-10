import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC

/// View for rendering a browser panel with address bar
struct BrowserPanelView: View {
    @ObservedObject var panel: BrowserPanel
    @ObservedObject var browserProfileStore = BrowserProfileStore.shared
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.openWindow) var openWindow
    @Environment(\.paneDropZone) var paneDropZone
    @State var omnibarState = OmnibarState()
    @State var addressBarFocused: Bool = false
    @AppStorage(BrowserSearchSettings.searchEngineKey) var searchEngineRaw = BrowserSearchSettings.defaultSearchEngine.rawValue
    @AppStorage(BrowserSearchSettings.customSearchEngineNameKey) var customSearchEngineName = BrowserSearchSettings.defaultCustomSearchEngineName
    @AppStorage(BrowserSearchSettings.customSearchEngineURLTemplateKey) var customSearchEngineURLTemplate = BrowserSearchSettings.defaultCustomSearchEngineURLTemplate
    @AppStorage(BrowserSearchSettings.searchSuggestionsEnabledKey) var searchSuggestionsEnabledStorage = BrowserSearchSettings.defaultSearchSuggestionsEnabled
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconNameKey) var devToolsIconNameRaw = BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconColorKey) var devToolsIconColorRaw = BrowserDevToolsButtonDebugSettings.defaultColor.rawValue
    @AppStorage(BrowserToolbarAccessorySpacingDebugSettings.key) var browserToolbarAccessorySpacingRaw = BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
    @AppStorage(BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
    var browserProfilePopoverHorizontalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
    @AppStorage(BrowserProfilePopoverDebugSettings.verticalPaddingKey)
    var browserProfilePopoverVerticalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultVerticalPadding
    @AppStorage(BrowserThemeSettings.modeKey) var browserThemeModeRaw = BrowserThemeSettings.defaultMode.rawValue
    @AppStorage(BrowserImportHintSettings.variantKey) var browserImportHintVariantRaw = BrowserImportHintSettings.defaultVariant.rawValue
    @AppStorage(BrowserImportHintSettings.showOnBlankTabsKey) var showBrowserImportHintOnBlankTabs = BrowserImportHintSettings.defaultShowOnBlankTabs
    @AppStorage(BrowserImportHintSettings.dismissedKey) var isBrowserImportHintDismissed = BrowserImportHintSettings.defaultDismissed
    @ObservedObject var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State var omnibarSuggestionRefreshScheduler = OmnibarSuggestionRefreshScheduler()
    @State var omnibarSuggestionRefreshConsumerTask: Task<Void, Never>?
    @State var suggestionTask: Task<Void, Never>?
    @State var isLoadingRemoteSuggestions: Bool = false
    @State var latestRemoteSuggestionQuery: String = ""
    @State var latestRemoteSuggestions: [String] = []
    @State var emptyStateImportBrowsers: [InstalledBrowserCandidate] = []
    @State var emptyStateImportBrowserRefreshTask: Task<Void, Never>?
    @State var emptyStateImportBrowserRefreshGeneration: UInt64 = 0
    @State var inlineCompletion: OmnibarInlineCompletion?
    @State var screenshotPageCopied: Bool = false
    @State var screenshotPageCaptureInProgress: Bool = false
    @State var screenshotPageCopiedTimer: Timer?
    @State var omnibarSelectionRange: NSRange = NSRange(location: NSNotFound, length: 0)
    @State var omnibarHasMarkedText: Bool = false
    @State var suppressNextFocusLostRevert: Bool = false
    @State var focusFlashOpacity: Double = 0.0
    @State var focusFlashAnimationGeneration: Int = 0
    @State var omnibarPillFrame: CGRect = .zero
    @State var addressBarHeight: CGFloat = 0
    @State var isBrowserImportHintPopoverPresented = false
    @State var focusModeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @State var lastHandledAddressBarFocusRequestId: UUID?
    @State var omnibarSelectAllRequestId: UInt64 = 0
    @State var pendingFocusGainedSelectionIntent: BrowserAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
    @State var isBrowserProfileMenuPresented = false
    @State var isBrowserThemeMenuPresented = false
    @State var browserChromeStyle: BrowserChromeStyle
    // The browser top chrome scales with the tab bar font size so tabs and the
    // browser toolbar share one consistent scale. Seeded from the cached config
    // and refreshed live on `.ghosttyConfigDidReload` (same path the tab strip
    // and terminal panels use). See `BrowserChromeMetrics`.
    @State var tabBarFontSize: CGFloat = GhosttyConfig.load().surfaceTabBarFontSize
    // `.onAppear` is not a reliable once-signal for a portal-hosted pane: it can
    // re-fire on every CoreAnimation commit (issue #5303). This guards the first-
    // appearance view-state seed (the empty-state import list) so a spurious appear
    // does no work. App-once settings work lives in the model bootstrap, not here.
    @State var didCompleteInitialBrowserPanelSetup = false
    // Keep this below half of the compact omnibar height so it reads as a squircle,
    // not a capsule.
    let omnibarPillCornerRadius: CGFloat = 10
    let addressBarVerticalPadding: CGFloat = 4
    // Toolbar/omnibar sizes derived from the tab bar font size. Names and call
    // sites are unchanged; the values now scale via `chromeMetrics`.
    var chromeMetrics: BrowserChromeMetrics {
        BrowserChromeMetrics(tabBarFontSize: tabBarFontSize)
    }
    var addressBarButtonSize: CGFloat { chromeMetrics.buttonIconSize }
    var addressBarButtonHitSize: CGFloat { chromeMetrics.buttonHitSize }
    var devToolsButtonIconSize: CGFloat { chromeMetrics.accessoryIconFontSize }

    init(
        panel: BrowserPanel,
        paneId: PaneID,
        isFocused: Bool,
        isVisibleInUI: Bool,
        portalPriority: Int,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        self.panel = panel
        self.paneId = paneId
        self.isFocused = isFocused
        self.isVisibleInUI = isVisibleInUI
        self.portalPriority = portalPriority
        self.onRequestPanelFocus = onRequestPanelFocus
        self._browserChromeStyle = State(initialValue: BrowserChromeStyle.resolve(
            for: .light,
            themeBackgroundColor: GhosttyBackgroundTheme.currentColor(),
            drawsBackground: panel.drawsConfiguredWebViewBackgroundForCurrentPage()
        ))
    }

    var body: some View {
        browserPanelLifecycleView
        .onReceive(NotificationCenter.default.publisher(for: .commandPaletteVisibilityDidChange)) { notification in
            handleCommandPaletteVisibilityChange(notification)
        }
        .onChange(of: panel.profileID) { _ in
            handleProfileChange()
        }
        .onChange(of: isVisibleInUI) { visibleInUI in
            handlePanelVisibilityChange(visibleInUI)
        }
        .onChange(of: isFocused) { focused in
            handlePanelFocusChange(focused)
        }
        .onChange(of: addressBarFocused) { focused in
            handleAddressBarFocusedChange(focused)
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserMoveOmnibarSelection)) { notification in
            handleMoveOmnibarSelection(notification)
        }
        .onReceive(panel.historyStore.$entries) { _ in
            handleHistoryEntriesChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserDidBlurAddressBar)) { notification in
            handleExternalAddressBarBlur(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
            refreshBrowserChromeStyle()
        }
    }

}

/// NSViewRepresentable wrapper for WKWebView
struct WebViewRepresentable: NSViewRepresentable {
    let panel: BrowserPanel
    let paneId: PaneID
    let shouldAttachWebView: Bool
    let useLocalInlineHosting: Bool
    let shouldFocusWebView: Bool
    let isPanelFocused: Bool
    let portalZPriority: Int
    let paneDropZone: DropZone?
    let searchOverlay: BrowserPortalSearchOverlayConfiguration?
    let omnibarSuggestions: BrowserPortalOmnibarSuggestionsConfiguration?
    let paneTopChromeHeight: CGFloat

    final class Coordinator {
        weak var panel: BrowserPanel?
        weak var webView: WKWebView?
        var attachGeneration: Int = 0
        var desiredPortalVisibleInUI: Bool = true
        var desiredPortalZPriority: Int = 0
        var lastPortalHostId: ObjectIdentifier?
        var lastSynchronizedHostGeometryRevision: UInt64 = 0
    }

    final class HostContainerView: NSView {
        final class HostedInspectorSideDockContainerView: NSView {
            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                wantsLayer = true
                layer?.masksToBounds = true
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                nil
            }

            override var isOpaque: Bool { false }

            override func resizeSubviews(withOldSize oldSize: NSSize) {
                // Managed side-docked DevTools use explicit frame updates from the host.
                // Letting AppKit autoresize the WK siblings here makes them snap back to
                // stale widths while the divider drag or pane resize is in flight.
            }
        }

        var onDidMoveToWindow: (() -> Void)?
        var onGeometryChanged: (() -> Void)?
        var geometryRevision: UInt64 = 0
        var lastReportedGeometryState: GeometryState?
        var hasPendingGeometryNotification = false
        weak var hostedWebView: WKWebView?
        var hostedWebViewConstraints: [NSLayoutConstraint] = []
        weak var localInlineSlotView: WindowBrowserSlotView?
        var localInlineSlotConstraints: [NSLayoutConstraint] = []
        weak var hostedInspectorSideDockContainerView: HostedInspectorSideDockContainerView?
        var hostedInspectorSideDockConstraints: [NSLayoutConstraint] = []
        weak var hostedInspectorFrontendWebView: WKWebView?
        struct HostedInspectorDividerHit {
            let containerView: NSView
            let pageView: NSView
            let inspectorView: NSView
            let dockSide: HostedInspectorDockSide
        }

        struct GeometryState: Equatable {
            let frame: CGRect
            let bounds: CGRect
            let windowNumber: Int?
            let superviewID: ObjectIdentifier?
        }

        struct HostedInspectorDividerDragState {
            let containerView: NSView
            let pageView: NSView
            let inspectorView: NSView
            let dockSide: HostedInspectorDockSide
            let initialWindowX: CGFloat
            let initialPageFrame: NSRect
            let initialInspectorFrame: NSRect
        }

        enum DividerCursorKind: Equatable {
            case vertical

            var cursor: NSCursor { .resizeLeftRight }
        }

        static let hostedInspectorDividerHitExpansion: CGFloat = 10
        static let minimumHostedInspectorWidth: CGFloat = 120
        static let minimumHostedInspectorPageWidthForSideDock: CGFloat = 240
        static let adaptiveBottomDockRequestCooldown: TimeInterval = 0.25
        var trackingArea: NSTrackingArea?
        var activeDividerCursorKind: DividerCursorKind?
        var hostedInspectorDividerDrag: HostedInspectorDividerDragState?
        var preferredHostedInspectorWidth: CGFloat?
        var preferredHostedInspectorWidthFraction: CGFloat?
        var onPreferredHostedInspectorWidthChanged: ((CGFloat, CGFloat?) -> Void)?
        weak var hostedInspectorSideDockPageView: NSView?
        weak var hostedInspectorSideDockInspectorView: NSView?
        var hostedInspectorSideDockDockSide: HostedInspectorDockSide?
        var isHostedInspectorDividerDragActive = false
        var isApplyingHostedInspectorLayout = false
        var hostedInspectorReapplyWorkItem: DispatchWorkItem?
        var hostedInspectorDockConfigurationSyncWorkItem: DispatchWorkItem?
        var adaptiveBottomDockRequestCooldownDeadline: Date?
        var recordedHostedInspectorSideDockWidth: CGFloat?
        var lastHostedInspectorManualSideDockAllowed: Bool?
        var lastHostedInspectorLayoutBoundsSize: NSSize?
#if DEBUG
        var lastLoggedHostedInspectorFrames: (page: NSRect, inspector: NSRect)?
        var hasLoggedMissingHostedInspectorCandidate = false
#endif

        deinit {
            hostedInspectorReapplyWorkItem?.cancel()
            hostedInspectorDockConfigurationSyncWorkItem?.cancel()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            clearActiveDividerCursor(restoreArrow: false)
        }

    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.panel = panel
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let container = HostContainerView()
        container.wantsLayer = true
        return container
    }

}
