import Bonsplit
import CmuxAppKitSupportUI
import CmuxBrowser
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import SwiftUI
import WebKit
import AppKit
import ObjectiveC
#if DEBUG
import CmuxTestSupport
#endif

// Both `CmuxBrowser` (the live import-hint settings) and `CmuxAppKitSupportUI`
// (its debug-panel preview copy) export these names; this file uses the live
// settings types, so pin the unqualified spellings to the `CmuxBrowser`
// versions to keep the lookup unambiguous.
private typealias BrowserImportHintVariant = CmuxBrowser.BrowserImportHintVariant
private typealias BrowserImportHintPresentation = CmuxBrowser.BrowserImportHintPresentation

private var cmuxBrowserPanelNeedsRenderingStateReattachKey: UInt8 = 0
let browserOmnibarTextFieldIdentifier = NSUserInterfaceItemIdentifier("cmux.browserOmnibarTextField")

private func browserPanelViewObjectID(_ object: AnyObject?) -> String {
    guard let object else { return "nil" }
    return String(describing: Unmanaged.passUnretained(object).toOpaque())
}

private func browserPanelViewRectDescription(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.width, rect.height)
}

private extension NSObject {
    @discardableResult
    func browserPanelCallVoidIfAvailable(_ rawSelector: String) -> Bool {
        let selector = NSSelectorFromString(rawSelector)
        guard responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
        return true
    }
}

private extension WKWebView {
    private var cmuxBrowserPanelNeedsRenderingStateReattach: Bool {
        get {
            (objc_getAssociatedObject(self, &cmuxBrowserPanelNeedsRenderingStateReattachKey) as? NSNumber)?
                .boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &cmuxBrowserPanelNeedsRenderingStateReattachKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    var cmuxBrowserPanelRequiresRenderingStateReattach: Bool {
        cmuxBrowserPanelNeedsRenderingStateReattach
    }

    var cmuxBrowserPanelIsInspectorFrontend: Bool {
        cmuxIsWebInspectorObject(self)
    }

    private func cmuxBrowserPanelApplyRenderingStateRefresh(
        reason: String,
        force: Bool
    ) {
        guard !cmuxBrowserPanelIsInspectorFrontend else {
#if DEBUG
            cmuxDebugLog(
                "browser.localHost.webview.skipInspectorLifecycle " +
                "web=\(browserPanelViewObjectID(self)) reason=\(reason)"
            )
#endif
            return
        }
        guard force || cmuxBrowserPanelNeedsRenderingStateReattach else { return }
        guard window != nil else { return }
        cmuxBrowserPanelNeedsRenderingStateReattach = false

        let firedSelectors = [
            "viewDidUnhide",
            "_enterInWindow",
            "_endDeferringViewInWindowChangesSync",
        ].filter {
            browserPanelCallVoidIfAvailable($0)
        }

        if let scrollView = enclosingScrollView {
            scrollView.needsLayout = true
            scrollView.needsDisplay = true
            scrollView.setNeedsDisplay(scrollView.bounds)
            scrollView.contentView.needsLayout = true
            scrollView.contentView.needsDisplay = true
        }

        needsLayout = true
        needsDisplay = true
        setNeedsDisplay(bounds)

#if DEBUG
        if !firedSelectors.isEmpty {
            cmuxDebugLog(
                "\(force ? "browser.localHost.webview.forceRefresh" : "browser.localHost.webview.reattach") " +
                "web=\(browserPanelViewObjectID(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ",")) " +
                "frame=\(browserPanelViewRectDescription(frame))"
            )
        }
#endif
    }

    func cmuxBrowserPanelNotifyHidden(reason: String) {
        guard !cmuxBrowserPanelIsInspectorFrontend else {
#if DEBUG
            cmuxDebugLog(
                "browser.localHost.webview.skipInspectorHidden " +
                "web=\(browserPanelViewObjectID(self)) reason=\(reason)"
            )
#endif
            return
        }
        cmuxBrowserPanelNeedsRenderingStateReattach = true
        let firedSelectors = ["viewDidHide", "_exitInWindow"].filter {
            browserPanelCallVoidIfAvailable($0)
        }
#if DEBUG
        if !firedSelectors.isEmpty {
            cmuxDebugLog(
                "browser.localHost.webview.hidden web=\(browserPanelViewObjectID(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ","))"
            )
        }
#endif
    }

    func cmuxBrowserPanelReattachRenderingState(reason: String) {
        cmuxBrowserPanelApplyRenderingStateRefresh(reason: reason, force: false)
    }

    func cmuxBrowserPanelForceRenderingStateRefresh(reason: String) {
        cmuxBrowserPanelApplyRenderingStateRefresh(reason: reason, force: true)
    }
}

enum BrowserDevToolsIconOption: String, CaseIterable, Identifiable {
    case wrenchAndScrewdriver = "wrench.and.screwdriver"
    case wrenchAndScrewdriverFill = "wrench.and.screwdriver.fill"
    case curlyBracesSquare = "curlybraces.square"
    case curlyBraces = "curlybraces"
    case terminalFill = "terminal.fill"
    case terminal = "terminal"
    case hammer = "hammer"
    case hammerCircle = "hammer.circle"
    case ladybug = "ladybug"
    case ladybugFill = "ladybug.fill"
    case scope = "scope"
    case codeChevrons = "chevron.left.slash.chevron.right"
    case gearshape = "gearshape"
    case gearshapeFill = "gearshape.fill"
    case globe = "globe"
    case globeAmericas = "globe.americas.fill"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wrenchAndScrewdriver: return "Wrench + Screwdriver"
        case .wrenchAndScrewdriverFill: return "Wrench + Screwdriver (Fill)"
        case .curlyBracesSquare: return "Curly Braces"
        case .curlyBraces: return "Curly Braces (Plain)"
        case .terminalFill: return "Terminal (Fill)"
        case .terminal: return "Terminal"
        case .hammer: return "Hammer"
        case .hammerCircle: return "Hammer Circle"
        case .ladybug: return "Bug"
        case .ladybugFill: return "Bug (Fill)"
        case .scope: return "Scope"
        case .codeChevrons: return "Code Chevrons"
        case .gearshape: return "Gear"
        case .gearshapeFill: return "Gear (Fill)"
        case .globe: return "Globe"
        case .globeAmericas: return "Globe Americas (Fill)"
        }
    }
}

enum BrowserDevToolsIconColorOption: String, CaseIterable, Identifiable {
    case bonsplitInactive
    case bonsplitActive
    case accent
    case tertiary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bonsplitInactive: return "Bonsplit Inactive (Terminal/Globe)"
        case .bonsplitActive: return "Bonsplit Active (Terminal/Globe)"
        case .accent: return "Accent"
        case .tertiary: return "Tertiary"
        }
    }

    var color: Color {
        switch self {
        case .bonsplitInactive:
            // Matches Bonsplit tab icon tint for inactive tabs.
            return Color(nsColor: .secondaryLabelColor)
        case .bonsplitActive:
            // Matches Bonsplit tab icon tint for active tabs.
            return Color(nsColor: .labelColor)
        case .accent:
            return cmuxAccentColor()
        case .tertiary:
            return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

enum BrowserDevToolsButtonDebugSettings {
    static let iconNameKey = "browserDevToolsIconName"
    static let iconColorKey = "browserDevToolsIconColor"
    static let defaultIcon = BrowserDevToolsIconOption.wrenchAndScrewdriver
    static let defaultColor = BrowserDevToolsIconColorOption.bonsplitInactive

    static func iconOption(defaults: UserDefaults = .standard) -> BrowserDevToolsIconOption {
        guard let raw = defaults.string(forKey: iconNameKey),
              let option = BrowserDevToolsIconOption(rawValue: raw) else {
            return defaultIcon
        }
        return option
    }

    static func colorOption(defaults: UserDefaults = .standard) -> BrowserDevToolsIconColorOption {
        guard let raw = defaults.string(forKey: iconColorKey),
              let option = BrowserDevToolsIconColorOption(rawValue: raw) else {
            return defaultColor
        }
        return option
    }

    static func copyPayload(defaults: UserDefaults = .standard) -> String {
        let icon = iconOption(defaults: defaults)
        let color = colorOption(defaults: defaults)
        return """
        browserDevToolsIconName=\(icon.rawValue)
        browserDevToolsIconColor=\(color.rawValue)
        """
    }
}

private struct OmnibarAddressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OmnibarAddressButtonStyleBody(configuration: configuration)
    }
}

private struct OmnibarAddressButtonStyleBody: View {
    let configuration: OmnibarAddressButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0.0 }
        if configuration.isPressed { return 0.16 }
        if isHovered { return 0.08 }
        return 0.0
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private extension Image {
    func cmuxFlatSymbolColorRendering() -> Image {
        // `symbolColorRenderingMode(.flat)` is not available in the current SDK
        // used by CI/local builds. Keep this modifier as a compatibility no-op.
        self
    }
}

func resolvedBrowserChromeBackgroundColor(
    for colorScheme: ColorScheme,
    themeBackgroundColor: NSColor,
    drawsBackground: Bool
) -> NSColor {
    guard drawsBackground else { return .clear }
    switch colorScheme {
    case .dark, .light:
        return themeBackgroundColor
    @unknown default:
        return themeBackgroundColor
    }
}

func resolvedBrowserChromeColorScheme(
    for colorScheme: ColorScheme,
    themeBackgroundColor: NSColor,
    windowBackgroundColor: NSColor = .windowBackgroundColor
) -> ColorScheme {
    let perceivedBackgroundColor = themeBackgroundColor.alphaComponent < 0.999
        ? cmuxCompositedNSColor(themeBackgroundColor, over: windowBackgroundColor)
        : themeBackgroundColor
    return cmuxReadableColorScheme(for: perceivedBackgroundColor)
}

func resolvedBrowserOmnibarPillBackgroundColor(
    for colorScheme: ColorScheme,
    themeBackgroundColor: NSColor
) -> NSColor {
    let darkenMix: CGFloat
    switch colorScheme {
    case .light:
        darkenMix = 0.04
    case .dark:
        darkenMix = 0.05
    @unknown default:
        darkenMix = 0.04
    }

    let blendedColor = themeBackgroundColor.blended(withFraction: darkenMix, of: .black) ?? themeBackgroundColor
    return blendedColor.withAlphaComponent(themeBackgroundColor.alphaComponent)
}

private struct BrowserChromeStyle {
    let backgroundColor: NSColor
    let colorScheme: ColorScheme
    let omnibarPillBackgroundColor: NSColor

    static func resolve(
        for colorScheme: ColorScheme,
        themeBackgroundColor: NSColor,
        drawsBackground: Bool
    ) -> BrowserChromeStyle {
        let backgroundColor = resolvedBrowserChromeBackgroundColor(
            for: colorScheme,
            themeBackgroundColor: themeBackgroundColor,
            drawsBackground: drawsBackground
        )
        let chromeColorScheme = resolvedBrowserChromeColorScheme(
            for: colorScheme,
            themeBackgroundColor: themeBackgroundColor
        )
        let omnibarPillBackgroundColor = resolvedBrowserOmnibarPillBackgroundColor(
            for: chromeColorScheme,
            themeBackgroundColor: themeBackgroundColor
        )
        return BrowserChromeStyle(
            backgroundColor: backgroundColor,
            colorScheme: chromeColorScheme,
            omnibarPillBackgroundColor: omnibarPillBackgroundColor
        )
    }
}

/// View for rendering a browser panel with address bar
struct BrowserPanelView: View {
    @ObservedObject var panel: BrowserPanel
    @ObservedObject private var browserProfileStore = BrowserProfileStore.shared
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cmuxCanvasInlineBrowserHosting) private var canvasInlineBrowserHosting
    @Environment(\.openWindow) private var openWindow
    @Environment(\.paneDropZone) private var paneDropZone
    /// Held detector instance; the view detects and summarizes installed browsers
    /// through this rather than the former `BrowserInstalledBrowserDetector` static
    /// namespace.
    private let installedBrowserDetector = BrowserInstalledBrowserDetector()
    @State private var omnibarState = OmnibarState()
    @State private var addressBarFocused: Bool = false
    @AppStorage(BrowserSearchSettingsStore.searchEngineKey) private var searchEngineRaw = BrowserSearchSettingsStore.defaultSearchEngine.rawValue
    @AppStorage(BrowserSearchSettingsStore.customSearchEngineNameKey) private var customSearchEngineName = BrowserSearchSettingsStore.defaultCustomSearchEngineName
    @AppStorage(BrowserSearchSettingsStore.customSearchEngineURLTemplateKey) private var customSearchEngineURLTemplate = BrowserSearchSettingsStore.defaultCustomSearchEngineURLTemplate
    @AppStorage(BrowserSearchSettingsStore.searchSuggestionsEnabledKey) private var searchSuggestionsEnabledStorage = BrowserSearchSettingsStore.defaultSearchSuggestionsEnabled
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconNameKey) private var devToolsIconNameRaw = BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconColorKey) private var devToolsIconColorRaw = BrowserDevToolsButtonDebugSettings.defaultColor.rawValue
    @AppStorage(BrowserToolbarAccessorySpacingStore.key) private var browserToolbarAccessorySpacingRaw = BrowserToolbarAccessorySpacingStore.defaultSpacing
    @AppStorage(BrowserProfilePopoverPaddingStore.horizontalPaddingKey)
    private var browserProfilePopoverHorizontalPaddingRaw = BrowserProfilePopoverPaddingStore.defaultHorizontalPadding
    @AppStorage(BrowserProfilePopoverPaddingStore.verticalPaddingKey)
    private var browserProfilePopoverVerticalPaddingRaw = BrowserProfilePopoverPaddingStore.defaultVerticalPadding
    @AppStorage(BrowserThemeSettings.modeKey) private var browserThemeModeRaw = BrowserThemeSettings.defaultMode.rawValue
    @AppStorage(BrowserImportHintSettings.variantKey) private var browserImportHintVariantRaw = BrowserImportHintSettings.defaultVariant.rawValue
    @AppStorage(BrowserImportHintSettings.showOnBlankTabsKey) private var showBrowserImportHintOnBlankTabs = BrowserImportHintSettings.defaultShowOnBlankTabs
    @AppStorage(BrowserImportHintSettings.dismissedKey) private var isBrowserImportHintDismissed = BrowserImportHintSettings.defaultDismissed
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @State private var omnibarSuggestionRefreshScheduler = OmnibarSuggestionRefreshScheduler()
    @State private var omnibarSuggestionRefreshConsumerTask: Task<Void, Never>?
    @State private var suggestionTask: Task<Void, Never>?
    @State private var isLoadingRemoteSuggestions: Bool = false
    @State private var latestRemoteSuggestionQuery: String = ""
    @State private var latestRemoteSuggestions: [String] = []
    @State private var emptyStateImportBrowsers: [InstalledBrowserCandidate] = []
    @State private var emptyStateImportBrowserRefreshTask: Task<Void, Never>?
    @State private var emptyStateImportBrowserRefreshGeneration: UInt64 = 0
    @State private var inlineCompletion: OmnibarInlineCompletion?
    @State private var screenshotPageCopied: Bool = false
    @State private var screenshotPageCaptureInProgress: Bool = false
    @State private var screenshotPageCopiedTimer: Timer?
    @State private var omnibarSelectionRange: NSRange = NSRange(location: NSNotFound, length: 0)
    @State private var omnibarHasMarkedText: Bool = false
    @State private var suppressNextFocusLostRevert: Bool = false
    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @State private var omnibarPillFrame: CGRect = .zero
    @State private var addressBarHeight: CGFloat = 0
    @State private var addressBarWidth: CGFloat = 0

    /// Below this chrome width the full accessory row would crowd out the
    /// omnibar, so the plain-action buttons collapse into an overflow menu.
    private static let compactChromeWidthThreshold: CGFloat = 420

    private var isChromeCompact: Bool {
        addressBarWidth > 0 && addressBarWidth < Self.compactChromeWidthThreshold
    }
    @State private var isBrowserImportHintPopoverPresented = false
    @State private var focusModeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @State private var lastHandledAddressBarFocusRequestId: UUID?
    @State private var omnibarSelectAllRequestId: UInt64 = 0
    @State private var pendingFocusGainedSelectionIntent: BrowserAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
    @State private var isBrowserProfileMenuPresented = false
    @State private var isBrowserThemeMenuPresented = false
    @State private var browserChromeStyle: BrowserChromeStyle
    // The browser top chrome scales with the tab bar font size so tabs and the
    // browser toolbar share one consistent scale. Seeded from the cached config
    // and refreshed live on `.ghosttyConfigDidReload` (same path the tab strip
    // and terminal panels use). See `BrowserChromeMetrics`.
    @State private var tabBarFontSize: CGFloat = GhosttyConfig.load().surfaceTabBarFontSize
    // `.onAppear` is not a reliable once-signal for a portal-hosted pane: it can
    // re-fire on every CoreAnimation commit (issue #5303). This guards the first-
    // appearance view-state seed (the empty-state import list) so a spurious appear
    // does no work. App-once settings work lives in the model bootstrap, not here.
    @State private var didCompleteInitialBrowserPanelSetup = false
    // Keep this below half of the compact omnibar height so it reads as a squircle,
    // not a capsule.
    private let omnibarPillCornerRadius: CGFloat = 10
    private let addressBarVerticalPadding: CGFloat = 4
    // Toolbar/omnibar sizes derived from the tab bar font size. Names and call
    // sites are unchanged; the values now scale via `chromeMetrics`.
    private var chromeMetrics: BrowserChromeMetrics {
        BrowserChromeMetrics(tabBarFontSize: tabBarFontSize)
    }
    private var addressBarButtonSize: CGFloat { chromeMetrics.buttonIconSize }
    private var addressBarButtonHitSize: CGFloat { chromeMetrics.buttonHitSize }
    private var devToolsButtonIconSize: CGFloat { chromeMetrics.accessoryIconFontSize }

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

    private var searchConfiguration: BrowserSearchConfiguration {
        BrowserSearchSettingsStore().configuration(
            engineRaw: searchEngineRaw,
            customName: customSearchEngineName,
            customURLTemplate: customSearchEngineURLTemplate
        )
    }

    private var searchSuggestionsEnabled: Bool {
        // Touch @AppStorage so SwiftUI invalidates this view when settings change.
        _ = searchSuggestionsEnabledStorage
        return BrowserSearchSettingsStore(defaults: .standard).currentSearchSuggestionsEnabled
    }

    private var remoteSuggestionsEnabled: Bool {
        // Deterministic UI-test hook: force remote path on even if a persisted
        // setting disabled suggestions in previous sessions.
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON"] != nil ||
            UserDefaults.standard.string(forKey: "CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON") != nil {
            return true
        }
        // Keep UI tests deterministic by disabling network suggestions when requested.
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] == "1" {
            return false
        }
        return searchSuggestionsEnabled
    }

    private var hasActionableOmnibarSuggestions: Bool {
        !omnibarHasMarkedText && !omnibarState.suggestions.isEmpty
    }

    private var devToolsIconOption: BrowserDevToolsIconOption {
        BrowserDevToolsIconOption(rawValue: devToolsIconNameRaw) ?? BrowserDevToolsButtonDebugSettings.defaultIcon
    }

    private var devToolsColorOption: BrowserDevToolsIconColorOption {
        BrowserDevToolsIconColorOption(rawValue: devToolsIconColorRaw) ?? BrowserDevToolsButtonDebugSettings.defaultColor
    }

    private var browserThemeMode: BrowserThemeMode {
        BrowserThemeSettings.mode(for: browserThemeModeRaw)
    }

    private var browserImportHintVariant: BrowserImportHintVariant {
        BrowserImportHintSettings.variant(for: browserImportHintVariantRaw)
    }

    private var browserImportHintPresentation: BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            variant: browserImportHintVariant,
            showOnBlankTabs: showBrowserImportHintOnBlankTabs,
            isDismissed: isBrowserImportHintDismissed
        )
    }

    private var browserToolbarAccessorySpacing: CGFloat {
        CGFloat(BrowserToolbarAccessorySpacingStore.resolved(browserToolbarAccessorySpacingRaw))
    }

    private var browserProfilePopoverHorizontalPadding: CGFloat {
        CGFloat(BrowserProfilePopoverPaddingStore.resolvedHorizontalPadding(browserProfilePopoverHorizontalPaddingRaw))
    }

    private var browserProfilePopoverVerticalPadding: CGFloat {
        CGFloat(BrowserProfilePopoverPaddingStore.resolvedVerticalPadding(browserProfilePopoverVerticalPaddingRaw))
    }

    private var browserChromeBackground: Color {
        Color(nsColor: browserChromeStyle.backgroundColor)
    }

    private var browserChromeBackgroundColor: NSColor {
        browserChromeStyle.backgroundColor
    }

    private var browserChromeColorScheme: ColorScheme {
        browserChromeStyle.colorScheme
    }

    private var browserContentAccessibilityIdentifier: String {
        "BrowserPanelContent.\(panel.id.uuidString)"
    }

    private var omnibarPillBackgroundColor: NSColor {
        browserChromeStyle.omnibarPillBackgroundColor
    }

    private var hasVisibleOmnibarSuggestions: Bool {
        panel.isOmnibarVisible && addressBarFocused && hasActionableOmnibarSuggestions && omnibarPillFrame.width > 0
    }

    private var shouldRenderOmnibarSuggestionsInPortal: Bool {
        hasVisibleOmnibarSuggestions &&
            panel.shouldRenderWebView &&
            !panel.shouldUseLocalInlineDeveloperToolsHosting()
    }

    private var shouldRenderOmnibarSuggestionsInSwiftUI: Bool {
        hasVisibleOmnibarSuggestions && !shouldRenderOmnibarSuggestionsInPortal
    }

    private var omnibarSuggestionsFrameInPortal: CGRect? {
        guard shouldRenderOmnibarSuggestionsInPortal else { return nil }
        let top = max(0, omnibarPillFrame.maxY + 3 - addressBarHeight)
        let height = OmnibarSuggestionsView.popupHeight(for: omnibarState.suggestions)
        guard omnibarPillFrame.width > 0, height > 0 else { return nil }
        return CGRect(
            x: omnibarPillFrame.minX,
            y: top,
            width: omnibarPillFrame.width,
            height: height
        )
    }

    private var portalOmnibarSuggestions: BrowserPortalOmnibarSuggestionsConfiguration? {
        guard let frame = omnibarSuggestionsFrameInPortal else { return nil }
        return BrowserPortalOmnibarSuggestionsConfiguration(
            panelId: panel.id,
            popupFrame: frame,
            colorScheme: browserChromeColorScheme,
            engineName: searchConfiguration.displayName,
            items: omnibarState.suggestions,
            selectedIndex: omnibarState.selectedSuggestionIndex,
            isLoadingRemoteSuggestions: isLoadingRemoteSuggestions,
            searchSuggestionsEnabled: remoteSuggestionsEnabled,
            onCommit: { item in
                commitSuggestion(item)
            },
            onHighlight: { idx in
                let effects = omnibarState.reduce(.highlightIndex(idx))
                applyOmnibarEffects(effects)
            }
        )
    }

    private var developerToolsButtonHelp: String {
        let base = String(localized: "browser.toggleDevTools", defaultValue: "Toggle Developer Tools")
        let _ = keyboardShortcutSettingsObserver.revision
        return "\(base) (\(KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools).displayString))"
    }

    private var browserImportHintSummary: String {
        installedBrowserDetector.summaryText(for: emptyStateImportBrowsers)
    }

    private var shouldShowToolbarImportHintChip: Bool {
        shouldShowEmptyStateImportOverlay && browserImportHintPresentation.blankTabPlacement == .toolbarChip
    }

    private var owningWorkspace: Workspace? {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId) else {
            return nil
        }
        return manager.tabs.first(where: { $0.id == panel.workspaceId })
    }

    private var isCurrentPaneOwner: Bool {
        guard let currentPaneId = owningWorkspace?.paneId(forPanelId: panel.id) else {
            return false
        }
        return currentPaneId.id == paneId.id
    }

    private var currentEventIsCommandPointerActivation: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseUp:
            break
        default:
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command)
    }

    private func handleReloadOrStopButtonAction() {
        if panel.isLoading {
#if DEBUG
            cmuxDebugLog("browser.stop panel=\(panel.id.uuidString.prefix(5))")
#endif
            panel.stopLoading()
            return
        }

        if panel.recoverTerminatedWebContent(reason: "toolbarReload") {
            return
        }

        if currentEventIsCommandPointerActivation {
#if DEBUG
            cmuxDebugLog("browser.reload.commandClickDuplicate panel=\(panel.id.uuidString.prefix(5))")
#endif
            guard let workspace = owningWorkspace else {
#if DEBUG
                cmuxDebugLog("browser.reload.commandClickDuplicate.abort panel=\(panel.id.uuidString.prefix(5)) reason=workspaceMissing")
#endif
                return
            }
            guard let newPanel = workspace.duplicateBrowserToRight(panelId: panel.id) else {
#if DEBUG
                cmuxDebugLog("browser.reload.commandClickDuplicate.abort panel=\(panel.id.uuidString.prefix(5)) reason=newPanelFailed")
#endif
                return
            }
#if DEBUG
            cmuxDebugLog(
                "browser.reload.commandClickDuplicate.done panel=\(panel.id.uuidString.prefix(5)) " +
                "newPanel=\(newPanel.id.uuidString.prefix(5))"
            )
#endif
            return
        }

#if DEBUG
        cmuxDebugLog("browser.reload panel=\(panel.id.uuidString.prefix(5))")
#endif
        panel.reload()
    }

    private func handleReloadButtonContextMenuAction() {
#if DEBUG
        cmuxDebugLog("browser.reload.contextMenu panel=\(panel.id.uuidString.prefix(5))")
#endif
        panel.reload()
    }

    private func handleHardRefreshButtonAction() {
#if DEBUG
        cmuxDebugLog("browser.hardRefresh.contextMenu panel=\(panel.id.uuidString.prefix(5))")
#endif
        panel.hardReload()
    }

    private func handleScreenshotPageButtonAction() {
        guard !screenshotPageCaptureInProgress else { return }
        screenshotPageCaptureInProgress = true
#if DEBUG
        cmuxDebugLog("browser.screenshot.page.toolbar panel=\(panel.id.uuidString.prefix(5))")
#endif
        Task { @MainActor in
            defer {
                screenshotPageCaptureInProgress = false
            }
            let didCopy = await panel.captureScreenshotPageToClipboard()
            guard didCopy else { return }
            showScreenshotPageCopiedIndicator()
        }
    }

    private func showScreenshotPageCopiedIndicator() {
        screenshotPageCopiedTimer?.invalidate()
        screenshotPageCopied = true
        screenshotPageCopiedTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { _ in
            MainActor.assumeIsolated {
                screenshotPageCopiedTimer = nil
                screenshotPageCopied = false
            }
        }
    }

    private func handleBrowserFocusModeButtonAction() {
        if !panel.toggleBrowserFocusMode(reason: "toolbarButton", focusWebView: true) {
            NSSound.beep()
        }
    }

    private var browserFocusModeButtonHelp: String {
        let format = String(localized: "browser.focusMode.helpWithShortcut.format", defaultValue: "%@ (%@)")
        if panel.isBrowserFocusModeActive {
            let title = String(localized: "browser.focusMode.exit.help", defaultValue: "Exit browser focus mode")
            // Active: show the double-Escape exit hint.
            return String(format: format, title, browserFocusModeShortcutHint)
        }
        let title = String(localized: "browser.focusMode.enter.help", defaultValue: "Enter browser focus mode")
        // Inactive: show the configured enter shortcut, if one is bound.
        guard let enterHint = browserFocusModeEnterShortcutHint else { return title }
        return String(format: format, title, enterHint)
    }

    private var browserFocusModeShortcutHint: String {
        String(localized: "browser.focusMode.shortcutHint", defaultValue: "Esc Esc")
    }

    private var browserFocusModeEnterShortcutHint: String? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleBrowserFocusMode)
        guard !shortcut.isUnbound else { return nil }
        return shortcut.displayString
    }

    private var shouldShowBrowserFocusModeShortcutHint: Bool {
        panel.isBrowserFocusModeActive &&
            panel.canToggleBrowserFocusMode &&
            (ShortcutHintDebugSettings().alwaysShowHints || (showModifierHoldHints && focusModeShortcutHintMonitor.isModifierPressed))
    }

    private func startFocusModeShortcutHintMonitorIfNeeded() {
        if showModifierHoldHints {
            focusModeShortcutHintMonitor.start()
        } else {
            focusModeShortcutHintMonitor.stop()
        }
    }

    private func handleBrowserPanelAppear() {
        // One-time setup must not re-run on every commit; `.onAppear` can re-fire
        // repeatedly for a portal-hosted pane (issue #5303). Everything below the
        // setup call is idempotent and cheap, and genuine state transitions are
        // already handled by the dedicated `.onChange` observers on `body`, so
        // re-running this per appear is harmless once the heavy/one-time work is
        // gated out.
        performInitialBrowserPanelSetupIfNeeded()
        startOmnibarSuggestionRefreshConsumer()
        refreshBrowserChromeStyle()
        panel.noteWebViewVisibility(
            isVisibleInUI && isCurrentPaneOwner,
            reason: "view.onAppear"
        )
        panel.refreshAppearanceDrivenColors()
        panel.setBrowserThemeMode(browserThemeMode)
        applyPendingAddressBarFocusRequestIfNeeded()
        syncURLFromPanel()
        // If the browser surface is focused but has no URL loaded yet, auto-focus the omnibar.
        autoFocusOmnibarIfBlank()
        syncWebViewResponderPolicyWithViewState(reason: "onAppear")
        panel.historyStore.loadIfNeeded()
#if DEBUG
        logBrowserFocusState(event: "view.onAppear")
#endif
        startFocusModeShortcutHintMonitorIfNeeded()
    }

    /// Runs the view-state initialization that should happen on first appearance,
    /// independent of how many times SwiftUI fires `.onAppear` for the same view
    /// instance.
    ///
    /// `.onAppear` is not a reliable once-or-on-transition signal for a portal-hosted
    /// browser pane — it can re-fire on every CoreAnimation commit (issue #5303).
    /// Default registration and settings normalization are app-once work and live in
    /// ``BrowserPanel/bootstrapBrowserDefaultsIfNeeded()`` (run from the model
    /// init), not here. This method only seeds view-local state: the initial
    /// empty-state import list, which `handleCurrentURLChange` refreshes on subsequent
    /// new-tab navigations.
    private func performInitialBrowserPanelSetupIfNeeded() {
        guard !didCompleteInitialBrowserPanelSetup else { return }
        didCompleteInitialBrowserPanelSetup = true
        refreshEmptyStateImportBrowsers()
    }

    private func handleOmnibarVisibilityChange(_ isVisible: Bool) {
        if !isVisible {
            hideSuggestions()
            setAddressBarFocused(false, reason: "omnibarVisibility.hidden")
            addressBarHeight = 0
        } else {
            applyPendingAddressBarFocusRequestIfNeeded()
        }
        syncWebViewResponderPolicyWithViewState(reason: "omnibarVisibilityChanged")
    }

    private func handleBrowserPanelDisappear() {
        stopOmnibarSuggestionRefreshConsumer()
        cancelPendingOmnibarSuggestionWork()
        focusModeShortcutHintMonitor.stop()
        screenshotPageCopiedTimer?.invalidate()
        screenshotPageCopiedTimer = nil
        screenshotPageCopied = false
    }

    private func handleBrowserWebViewClickIntent(_ notification: Notification) {
        guard let webView = notification.object as? CmuxWebView,
              webView === panel.webView else {
            return
        }
#if DEBUG
        cmuxDebugLog(
            "browser.focus.clickIntent panel=\(panel.id.uuidString.prefix(5)) " +
            "isFocused=\(isFocused ? 1 : 0) " +
            "addressFocused=\(addressBarFocused ? 1 : 0)"
        )
#endif
        if addressBarFocused {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.webViewClickBlur")
#endif
            setAddressBarFocused(false, reason: "webView.clickIntent")
        }
        if !isFocused {
            onRequestPanelFocus()
        }
    }

    private func handleExternalAddressBarBlur(_ notification: Notification) {
        guard let panelId = notification.object as? UUID,
              panelId == panel.id,
              addressBarFocused else {
            return
        }
#if DEBUG
        logBrowserFocusState(event: "addressBarFocus.externalBlur")
#endif
        setAddressBarFocused(false, reason: "notification.externalBlur")
    }

    private func handleCurrentURLChange() {
        refreshBrowserChromeStyle()
        let addressWasEmpty = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        syncURLFromPanel()
        // If we auto-focused a blank omnibar but then a URL loads programmatically, move focus
        // into WebKit unless the user had already started typing.
        if addressBarFocused,
           !panel.shouldSuppressWebViewFocus(),
           addressWasEmpty,
           !isBrowserContentBlankForOmnibar() {
            setAddressBarFocused(false, reason: "panel.currentURL.loaded")
        }
        if panel.isShowingNewTabPage {
            refreshEmptyStateImportBrowsers()
        }
        panel.resetReactGrabState(
            preserveRoundTrip: true,
            reason: "panel.currentURL.changed"
        )
    }

    private func handleRenderWebViewChange() {
        refreshBrowserChromeStyle()
        if panel.isShowingNewTabPage {
            refreshEmptyStateImportBrowsers()
        }
    }

    private func handleBrowserThemeModeRawChange() {
        let normalizedMode = BrowserThemeSettings.mode(for: browserThemeModeRaw)
        if browserThemeModeRaw != normalizedMode.rawValue {
            browserThemeModeRaw = normalizedMode.rawValue
        }
        panel.setBrowserThemeMode(normalizedMode)
    }

    private func handleSystemColorSchemeChange() {
        refreshBrowserChromeStyle()
        panel.refreshAppearanceDrivenColors()
    }

    private func handleCommandPaletteVisibilityChange(_ notification: Notification) {
        guard commandPaletteVisibilityNotificationMatchesPanelWindow(notification) else { return }
        applyPendingAddressBarFocusRequestIfNeeded()
    }

    private func handleProfileChange() {
        panel.historyStore.loadIfNeeded()
        if addressBarFocused {
            refreshSuggestions()
        }
    }

    private func handlePanelVisibilityChange(_ visibleInUI: Bool) {
        let effectiveVisibility = visibleInUI && isCurrentPaneOwner
        panel.noteWebViewVisibility(
            effectiveVisibility,
            reason: effectiveVisibility ? "view.visible" : "view.hidden"
        )
        if visibleInUI {
            panel.cancelPendingDeveloperToolsVisibilityLossCheck()
            return
        }
        if panel.shouldUseLocalInlineDeveloperToolsHosting() {
            // Workspace switches keep the attached inspector alive off-screen.
            // Treating that hide as a manual X-close can clear the restore intent
            // before the original local-inline host becomes visible again.
            panel.cancelPendingDeveloperToolsVisibilityLossCheck()
            return
        }
        // Pane/workspace churn can briefly mark the browser hidden before the
        // final host settles. Only treat a stable hide as a signal to consume
        // an attached-inspector X-close.
        panel.scheduleDeveloperToolsVisibilityLossCheck()
    }

    private func handlePanelFocusChange(_ focused: Bool) {
#if DEBUG
        logBrowserFocusState(
            event: "panelFocus.onChange",
            detail: "next=\(focused ? 1 : 0)"
        )
#endif
        // Ensure this view doesn't retain focus while hidden (bonsplit keepAllAlive).
        if focused {
            applyPendingAddressBarFocusRequestIfNeeded()
            autoFocusOmnibarIfBlank()
        } else {
            panel.invalidateAddressBarPageFocusRestoreAttempts()
            panel.clearBrowserFocusMode(reason: "panelFocus.onChange.unfocused")
            hideSuggestions()
            setAddressBarFocused(false, reason: "panelFocus.onChange.unfocused")
            // Surface switches in split layouts can keep the browser visible, so
            // `isVisibleInUI` never flips to false. Check for an attached-inspector
            // X-close when focus leaves as well so the persisted intent stays in sync.
            DispatchQueue.main.async {
                guard isVisibleInUI else { return }
                panel.scheduleDeveloperToolsVisibilityLossCheck()
            }
        }
        syncWebViewResponderPolicyWithViewState(
            reason: "panelFocusChanged",
            isPanelFocusedOverride: focused
        )
    }

    private func handleAddressBarFocusedChange(_ focused: Bool) {
#if DEBUG
        logBrowserFocusState(
            event: "addressBarFocus.onChange",
            detail: "next=\(focused ? 1 : 0)"
        )
#endif
        let urlString = panel.preferredURLStringForOmnibar() ?? ""
        if focused {
            let selectionIntent = pendingFocusGainedSelectionIntent
            pendingFocusGainedSelectionIntent = .preserveFieldEditorSelection
            panel.beginSuppressWebViewFocusForAddressBar()
            NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: panel.id)
            // Only request panel focus if this pane isn't currently focused. When already
            // focused (e.g. Cmd+L), forcing focus can steal first responder back to WebKit.
            if !isFocused {
#if DEBUG
                logBrowserFocusState(event: "addressBarFocus.requestPanelFocus")
#endif
                onRequestPanelFocus()
            }
            let effects = omnibarState.reduce(.focusGained(currentURLString: urlString, shouldSelectAll: selectionIntent.shouldSelectAll)
            )
            applyOmnibarEffects(effects)
            refreshInlineCompletion()
        } else {
            pendingFocusGainedSelectionIntent = .preserveFieldEditorSelection
            panel.endSuppressWebViewFocusForAddressBar()
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panel.id)
            if suppressNextFocusLostRevert {
                suppressNextFocusLostRevert = false
                let effects = omnibarState.reduce(.focusLostPreserveBuffer(currentURLString: urlString))
                applyOmnibarEffects(effects)
            } else {
                let effects = omnibarState.reduce(.focusLostRevertBuffer(currentURLString: urlString))
                applyOmnibarEffects(effects)
            }
            inlineCompletion = nil
        }
        syncWebViewResponderPolicyWithViewState(reason: "addressBarFocusChanged")
#if DEBUG
        logBrowserFocusState(event: "addressBarFocus.onChange.applied")
#endif
    }

    private func handleMoveOmnibarSelection(_ notification: Notification) {
        guard let panelId = notification.object as? UUID, panelId == panel.id else { return }
        guard canHandleOmnibarSuggestionInteraction() else { return }
        guard let delta = notification.userInfo?["delta"] as? Int, delta != 0 else { return }
#if DEBUG
        logBrowserFocusState(event: "addressBarFocus.moveSelection", detail: "delta=\(delta)")
#endif
        let effects = omnibarState.reduce(.moveSelection(delta: delta))
        applyOmnibarEffects(effects)
        refreshInlineCompletion()
    }

    private func handleHistoryEntriesChange() {
        guard addressBarFocused else { return }
        refreshSuggestions()
    }

    @ViewBuilder
    private var browserFindOverlayView: some View {
        // Keep browser find usable when the browser is still in the empty new-tab
        // state (no WKWebView mounted yet). WebView-backed cases are hosted
        // in AppKit by WindowBrowserPortal to avoid layering/clipping issues.
        if !panel.shouldRenderWebView, let searchState = panel.searchState {
            BrowserSearchOverlay(
                panelId: panel.id,
                searchState: searchState,
                focusRequestGeneration: panel.searchFocusRequestGeneration,
                canApplyFocusRequest: { generation in
                    canApplyBrowserFindFieldFocusRequest(generation)
                },
                onNext: { panel.findNext() },
                onPrevious: { panel.findPrevious() },
                onClose: { panel.hideFind() },
                onFieldDidFocus: { panel.noteFindFieldFocused() }
            )
        }
    }

    private var focusFlashOverlayView: some View {
        RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
            .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
            .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
            .padding(FocusFlashPattern.ringInset)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var omnibarSuggestionsOverlayView: some View {
        if shouldRenderOmnibarSuggestionsInSwiftUI {
            OmnibarSuggestionsView(
                engineName: searchConfiguration.displayName,
                items: omnibarState.suggestions,
                selectedIndex: omnibarState.selectedSuggestionIndex,
                isLoadingRemoteSuggestions: isLoadingRemoteSuggestions,
                searchSuggestionsEnabled: remoteSuggestionsEnabled,
                onCommit: { item in
                    commitSuggestion(item)
                },
                onHighlight: { idx in
                    let effects = omnibarState.reduce(.highlightIndex(idx))
                    applyOmnibarEffects(effects)
                }
            )
            .frame(width: omnibarPillFrame.width)
            .offset(x: omnibarPillFrame.minX, y: omnibarPillFrame.maxY + 3)
            .zIndex(1000)
            .environment(\.colorScheme, browserChromeColorScheme)
        }
    }

    @ViewBuilder
    private var omnibarHeaderView: some View {
        if panel.isOmnibarVisible {
            addressBar
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var browserPanelBaseView: some View {
        // Layering contract: browser find UI is mounted in the portal-hosted AppKit
        // container. Rendering it here can hide it behind the portal-hosted WKWebView.
        VStack(spacing: 0) {
            omnibarHeaderView
            webView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(browserFindOverlayView)
        .overlay(focusFlashOverlayView)
        .overlay(omnibarSuggestionsOverlayView, alignment: .topLeading)
    }

    private var browserPanelLifecycleView: some View {
        browserPanelBaseView
        .coordinateSpace(name: "BrowserPanelViewSpace")
        .onPreferenceChange(OmnibarPillFramePreferenceKey.self) { frame in
            omnibarPillFrame = frame
        }
        .onPreferenceChange(BrowserAddressBarHeightPreferenceKey.self) { height in
            addressBarHeight = height
        }
        .onPreferenceChange(BrowserAddressBarWidthPreferenceKey.self) { width in
            addressBarWidth = width
        }
        .onReceive(NotificationCenter.default.publisher(for: .webViewDidReceiveClick)) { notification in
            handleBrowserWebViewClickIntent(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            tabBarFontSize = GhosttyConfig.load().surfaceTabBarFontSize
        }
        .onAppear {
            handleBrowserPanelAppear()
        }
        .onDisappear {
            handleBrowserPanelDisappear()
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
        .onChange(of: panel.currentURL) { _ in
            handleCurrentURLChange()
        }
        .onChange(of: panel.shouldRenderWebView) { _, _ in
            handleRenderWebViewChange()
        }
        .onChange(of: panel.backgroundAppearanceRevision) { _, _ in
            refreshBrowserChromeStyle()
        }
        .onChange(of: browserThemeModeRaw) { _ in
            handleBrowserThemeModeRawChange()
        }
        .onChange(of: colorScheme) { _ in
            handleSystemColorSchemeChange()
        }
        .onChange(of: panel.pendingAddressBarFocusRequestId) { _ in
            applyPendingAddressBarFocusRequestIfNeeded()
        }
        .onChange(of: panel.isOmnibarVisible) { _, isVisible in
            handleOmnibarVisibilityChange(isVisible)
        }
        .onChange(of: showModifierHoldHints) { _, _ in
            startFocusModeShortcutHintMonitorIfNeeded()
        }
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

    private var addressBar: some View {
        HStack(spacing: 8) {
            addressBarButtonBar

            omnibarField
                .accessibilityIdentifier("BrowserOmnibarPill")
                .accessibilityLabel("Browser omnibar")

            HStack(spacing: browserToolbarAccessorySpacing) {
                if shouldShowToolbarImportHintChip {
                    browserImportHintToolbarChip
                }
                if isChromeCompact {
                    // Narrow panes can't fit the full accessory row without
                    // clipping the omnibar; collapse the plain-action buttons
                    // into an overflow menu and keep the popover-anchored
                    // profile/theme controls present.
                    browserOverflowMenu
                    browserProfileButton
                    browserThemeModeButton
                } else {
                    browserFocusModeButtonWithShortcutHint
                    screenshotPageButton
                    reactGrabButton
                    browserProfileButton
                    browserThemeModeButton
                    developerToolsButton
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, addressBarVerticalPadding)
        .background(browserChromeBackground)
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: BrowserAddressBarWidthPreferenceKey.self,
                    value: geo.size.width
                )
            }
        }
        .background(
            WindowAccessor(refreshID: showModifierHoldHints) { window in
                focusModeShortcutHintMonitor.setHostWindow(showModifierHoldHints ? window : nil)
            }
        )
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: BrowserAddressBarHeightPreferenceKey.self,
                        value: geo.size.height
                    )
            }
        }
        // Keep the omnibar stack above WKWebView so the suggestions popup is visible.
        .zIndex(1)
        .environment(\.colorScheme, browserChromeColorScheme)
    }

    private var addressBarButtonBar: some View {
        return HStack(spacing: 0) {
            Button(action: {
                #if DEBUG
                cmuxDebugLog("browser.back panel=\(panel.id.uuidString.prefix(5))")
                #endif
                panel.goBack()
            }) {
                Image(systemName: "chevron.left")
                    .cmuxSymbolRasterSize(chromeMetrics.navigationIconFontSize, weight: .medium)
                    .frame(width: addressBarButtonHitSize, height: addressBarButtonHitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .disabled(!panel.canGoBack)
            .opacity(panel.canGoBack ? 1.0 : 0.4)
            .safeHelp(String(localized: "browser.goBack", defaultValue: "Go Back"))

            Button(action: {
                #if DEBUG
                cmuxDebugLog("browser.forward panel=\(panel.id.uuidString.prefix(5))")
                #endif
                panel.goForward()
            }) {
                Image(systemName: "chevron.right")
                    .cmuxSymbolRasterSize(chromeMetrics.navigationIconFontSize, weight: .medium)
                    .frame(width: addressBarButtonHitSize, height: addressBarButtonHitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .disabled(!panel.canGoForward)
            .opacity(panel.canGoForward ? 1.0 : 0.4)
            .safeHelp(String(localized: "browser.goForward", defaultValue: "Go Forward"))

            Button(action: handleReloadOrStopButtonAction) {
                Image(systemName: panel.isLoading ? "xmark" : "arrow.clockwise")
                    .cmuxSymbolRasterSize(chromeMetrics.navigationIconFontSize, weight: .medium)
                    .frame(width: addressBarButtonHitSize, height: addressBarButtonHitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .contextMenu {
                Button(String(localized: "browser.reload", defaultValue: "Reload")) {
                    handleReloadButtonContextMenuAction()
                }
                Button(String(localized: "menu.view.hardRefresh", defaultValue: "Hard Refresh")) {
                    handleHardRefreshButtonAction()
                }
            }
            .safeHelp(panel.isLoading ? String(localized: "browser.stop", defaultValue: "Stop") : String(localized: "browser.reload", defaultValue: "Reload"))

            if panel.isDownloading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "browser.downloading", defaultValue: "Downloading..."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 6)
                .safeHelp(String(localized: "browser.downloadInProgress", defaultValue: "Download in progress"))
            }
        }
    }

    private var screenshotPageButton: some View {
        Button(action: handleScreenshotPageButtonAction) {
            Image(systemName: screenshotPageCopied ? "checkmark" : "camera")
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .cmuxSymbolRasterSize(devToolsButtonIconSize, weight: .medium)
                .foregroundStyle(screenshotPageButtonColor)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .disabled(!panel.shouldRenderWebView || screenshotPageCaptureInProgress)
        .opacity(panel.shouldRenderWebView ? 1.0 : 0.4)
        .safeHelp(
            screenshotPageCopied
                ? String(localized: "browser.screenshotPage.copied.help", defaultValue: "Screenshot copied to clipboard")
                : String(localized: "browser.screenshotPage.copy.help", defaultValue: "Screenshot Page to Clipboard")
        )
        .accessibilityIdentifier("BrowserScreenshotPageButton")
        .overlay(alignment: .top) {
            if screenshotPageCopied {
                Label(String(localized: "browser.screenshotPage.copied", defaultValue: "Copied"), systemImage: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .fixedSize()
                    .offset(y: -28)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: screenshotPageCopied)
    }

    private var browserFocusModeButtonWithShortcutHint: some View {
        ZStack(alignment: .top) {
            browserFocusModeButton
            if shouldShowBrowserFocusModeShortcutHint {
                ShortcutHintPill(text: browserFocusModeShortcutHint, fontSize: 9, emphasis: 1.05)
                    .offset(y: -22)
                    .shortcutHintTransition()
                    .accessibilityIdentifier("BrowserFocusModeShortcutHint")
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .shortcutHintVisibilityAnimation(value: shouldShowBrowserFocusModeShortcutHint)
    }

    private var browserFocusModeButton: some View {
        Button(action: handleBrowserFocusModeButtonAction) {
            HStack(spacing: 5) {
                Image(systemName: "keyboard")
                    .cmuxSymbolRasterSize(devToolsButtonIconSize, weight: .medium)
                    .scaleEffect(panel.isBrowserFocusModeActive ? 1.08 : 1.0)
                    .animation(.spring(response: 0.18, dampingFraction: 0.82), value: panel.isBrowserFocusModeActive)
                if panel.isBrowserFocusModeActive {
                    Text(
                        panel.isBrowserFocusModeExitArmed
                            ? String(localized: "browser.focusMode.armed", defaultValue: "Esc again to exit")
                            : String(localized: "browser.focusMode.active", defaultValue: "Focus Mode")
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .foregroundStyle(panel.isBrowserFocusModeActive ? Color.orange : devToolsColorOption.color)
            .padding(.horizontal, panel.isBrowserFocusModeActive ? 7 : 0)
            .frame(
                minWidth: panel.isBrowserFocusModeActive ? 0 : addressBarButtonSize,
                minHeight: addressBarButtonSize,
                alignment: .center
            )
            .animation(.easeOut(duration: 0.14), value: panel.isBrowserFocusModeActive)
            .animation(.easeOut(duration: 0.12), value: panel.isBrowserFocusModeExitArmed)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(height: addressBarButtonSize, alignment: .center)
        .disabled(!panel.canToggleBrowserFocusMode)
        .opacity(panel.canToggleBrowserFocusMode ? 1.0 : 0.4)
        .safeHelp(browserFocusModeButtonHelp)
        .accessibilityIdentifier("BrowserFocusModeButton")
    }

    private var screenshotPageButtonColor: Color {
        if screenshotPageCopied {
            return .green
        }
        return panel.shouldRenderWebView ? devToolsColorOption.color : Color.secondary
    }

    private var reactGrabButton: some View {
        Button(action: {
            panel.clearReactGrabRoundTrip(reason: "toolbarButton.manualStart")
            Task { await panel.toggleOrInjectReactGrab() }
        }) {
            Image(systemName: "cursorarrow.click.2")
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .cmuxSymbolRasterSize(devToolsButtonIconSize, weight: .medium)
                .foregroundStyle(panel.isReactGrabActive ? Color.accentColor : Color.secondary)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .safeHelp(String(localized: "browser.reactGrab", defaultValue: "Inject React Grab"))
        .accessibilityIdentifier("BrowserReactGrabButton")
    }

    private var developerToolsButton: some View {
        Button(action: {
            openDevTools()
        }) {
            Image(systemName: devToolsIconOption.rawValue)
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .cmuxSymbolRasterSize(devToolsButtonIconSize, weight: .medium)
                .foregroundStyle(devToolsColorOption.color)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .safeHelp(developerToolsButtonHelp)
        .accessibilityIdentifier("BrowserToggleDevToolsButton")
    }

    private var browserProfileButton: some View {
        Button(action: {
            isBrowserProfileMenuPresented.toggle()
        }) {
            Image(systemName: "person.crop.circle")
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .cmuxSymbolRasterSize(devToolsButtonIconSize, weight: .medium)
                .foregroundStyle(devToolsColorOption.color)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .popover(isPresented: $isBrowserProfileMenuPresented, arrowEdge: .bottom) {
            browserProfilePopover
        }
        .safeHelp(
            String(
                format: String(
                    localized: "browser.profile.buttonHelp",
                    defaultValue: "Browser Profile: %@"
                ),
                panel.profileDisplayName
            )
        )
        .accessibilityIdentifier("BrowserProfileButton")
    }

    /// Overflow menu shown in compact chrome: the plain-action accessory
    /// buttons (focus mode, screenshot, React Grab, dev tools) as menu items.
    /// Profile and theme stay as visible buttons since they anchor popovers.
    private var browserOverflowMenu: some View {
        Menu {
            Button(action: handleBrowserFocusModeButtonAction) {
                Label(
                    panel.isBrowserFocusModeActive
                        ? String(localized: "browser.focusMode.active", defaultValue: "Focus Mode")
                        : String(localized: "browser.focusMode.enter", defaultValue: "Enter Focus Mode"),
                    systemImage: "keyboard"
                )
            }
            .disabled(!panel.canToggleBrowserFocusMode)

            Button(action: handleScreenshotPageButtonAction) {
                Label(
                    String(localized: "browser.screenshotPage.copy.help", defaultValue: "Screenshot Page to Clipboard"),
                    systemImage: "camera"
                )
            }
            .disabled(!panel.shouldRenderWebView)

            Button {
                panel.clearReactGrabRoundTrip(reason: "overflowMenu.manualStart")
                Task { await panel.toggleOrInjectReactGrab() }
            } label: {
                Label(
                    String(localized: "browser.reactGrab", defaultValue: "Inject React Grab"),
                    systemImage: "cursorarrow.click.2"
                )
            }

            Button(action: { openDevTools() }) {
                Label(developerToolsButtonHelp, systemImage: devToolsIconOption.rawValue)
            }
        } label: {
            Image(systemName: "ellipsis")
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .font(.system(size: devToolsButtonIconSize, weight: .medium))
                .foregroundStyle(devToolsColorOption.color)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .safeHelp(String(localized: "browser.moreActions", defaultValue: "More Actions"))
        .accessibilityIdentifier("BrowserOverflowMenu")
    }

    private var browserThemeModeButton: some View {
        Button(action: {
            isBrowserThemeMenuPresented.toggle()
        }) {
            Image(systemName: browserThemeMode.iconName)
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .cmuxSymbolRasterSize(devToolsButtonIconSize, weight: .medium)
                .foregroundStyle(browserThemeModeIconColor)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .popover(isPresented: $isBrowserThemeMenuPresented, arrowEdge: .bottom) {
            browserThemeModePopover
        }
        .safeHelp(
            String(
                format: String(
                    localized: "browser.theme.buttonHelp",
                    defaultValue: "Browser Theme: %@"
                ),
                browserThemeMode.displayName
            )
        )
        .accessibilityIdentifier("BrowserThemeModeButton")
    }

    private var browserImportHintToolbarChip: some View {
        Button(action: {
            isBrowserImportHintPopoverPresented.toggle()
        }) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .cmuxSymbolRasterSize(10, weight: .medium)
                Text(String(localized: "browser.import.hint.toolbar", defaultValue: "Import"))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(devToolsColorOption.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .popover(isPresented: $isBrowserImportHintPopoverPresented, arrowEdge: .bottom) {
            browserImportHintPopover
        }
        .safeHelp(String(localized: "browser.import.hint.toolbar.help", defaultValue: "Import browser data"))
        .accessibilityIdentifier("BrowserImportHintToolbarChip")
    }

    private var browserProfilePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.profile.menu.title", defaultValue: "Profiles"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(browserProfileStore.profiles) { profile in
                    Button {
                        applyBrowserProfileSelection(profile.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: profile.id == panel.profileID ? "checkmark" : "circle")
                                .cmuxSymbolRasterSize(10, weight: .semibold)
                                .opacity(profile.id == panel.profileID ? 1.0 : 0.0)
                                .frame(width: 12, alignment: .center)
                            Text(profile.displayName)
                                .font(.system(size: 12))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(profile.id == panel.profileID ? Color.primary.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button {
                isBrowserProfileMenuPresented = false
                presentCreateBrowserProfilePrompt()
            } label: {
                Text(String(localized: "browser.profile.new", defaultValue: "New Profile..."))
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Button {
                presentImportDialogFromProfileMenu()
            } label: {
                Text(String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"))
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            if browserProfileStore.canRenameProfile(id: panel.profileID) {
                Button {
                    isBrowserProfileMenuPresented = false
                    presentRenameBrowserProfilePrompt()
                } label: {
                    Text(String(localized: "browser.profile.rename", defaultValue: "Rename Current Profile..."))
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, browserProfilePopoverHorizontalPadding)
        .padding(.vertical, browserProfilePopoverVerticalPadding)
        .frame(minWidth: 208)
    }

    private var browserThemeModePopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(BrowserThemeMode.allCases) { mode in
                Button {
                    applyBrowserThemeModeSelection(mode)
                    isBrowserThemeMenuPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mode == browserThemeMode ? "checkmark" : "circle")
                            .cmuxSymbolRasterSize(10, weight: .semibold)
                            .opacity(mode == browserThemeMode ? 1.0 : 0.0)
                            .frame(width: 12, alignment: .center)
                        Text(mode.displayName)
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(mode == browserThemeMode ? Color.primary.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("BrowserThemeModeOption\(mode.rawValue.capitalized)")
            }
        }
        .padding(8)
        .frame(minWidth: 128)
    }

    private var browserThemeModeIconColor: Color {
        devToolsColorOption.color
    }

    private var omnibarField: some View {
        let showSecureBadge = panel.currentURL?.scheme == "https"

        return HStack(spacing: 4) {
            if showSecureBadge {
                Image(systemName: "lock.fill")
                    .cmuxSymbolRasterSize(chromeMetrics.secureBadgeFontSize)
                    .foregroundColor(.secondary)
            }

            OmnibarTextFieldRepresentable(
                panelId: panel.id,
                fontSize: chromeMetrics.omnibarFontSize,
                text: Binding(
                    get: { omnibarState.buffer },
                    set: { newValue in
                        let effects = omnibarState.reduce(.bufferChanged(newValue))
                        applyOmnibarEffects(effects)
                        if !effects.shouldClearInlineCompletion {
                            refreshInlineCompletion()
                        }
                    }
                ),
                isFocused: $addressBarFocused,
                selectAllRequestId: omnibarSelectAllRequestId,
                inlineCompletion: inlineCompletion,
                placeholder: String(localized: "browser.addressBar.placeholder", defaultValue: "Search or enter URL"),
                onTap: {
                    handleOmnibarTap()
                },
                onSubmit: { liveField in
                    handleOmnibarSubmit(liveField: liveField)
                },
                onEscape: {
                    handleOmnibarEscape()
                },
                onFieldLostFocus: {
                    setAddressBarFocused(false, reason: "omnibar.fieldLostFocus")
                },
                onMoveSelection: { delta in
                    guard canHandleOmnibarSuggestionInteraction() else { return }
                    let effects = omnibarState.reduce(.moveSelection(delta: delta))
                    applyOmnibarEffects(effects)
                    refreshInlineCompletion()
                },
                onDeleteSelectedSuggestion: {
                    deleteSelectedSuggestionIfPossible()
                },
                onAcceptInlineCompletion: {
                    acceptInlineCompletion()
                },
                onDeleteBackwardWithInlineSelection: {
                    handleInlineBackspace()
                },
                onClearTypedPrefixWithInlineSelection: {
                    handleInlineClearTypedPrefix()
                },
                onDeleteWordBackwardWithInlineSelection: {
                    handleInlineDeleteWordBackward()
                },
                onSelectionChanged: { selectionRange, hasMarkedText in
                    handleOmnibarSelectionChange(range: selectionRange, hasMarkedText: hasMarkedText)
                },
                shouldSuppressWebViewFocus: {
                    panel.shouldSuppressWebViewFocus()
                }
            )
                .frame(height: chromeMetrics.omnibarFieldHeight)
                .accessibilityIdentifier("BrowserOmnibarTextField")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: omnibarPillCornerRadius, style: .continuous)
                .fill(Color(nsColor: omnibarPillBackgroundColor))
        )
        .overlay {
            BrowserOmnibarInteractionRepresentable(panelId: panel.id)
        }
        .overlay(
            RoundedRectangle(cornerRadius: omnibarPillCornerRadius, style: .continuous)
                .stroke(addressBarFocused ? cmuxAccentColor() : Color.clear, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: OmnibarPillFramePreferenceKey.self,
                        value: geo.frame(in: .named("BrowserPanelViewSpace"))
                    )
            }
        }
    }

    private var webView: some View {
        // Canvas-hosted panes force inline hosting: window-portal positioning
        // visibly trails the pane during canvas pans (out-of-process WebKit
        // compositing), and portal content cannot scale with magnification.
        let useLocalInlineDeveloperToolsHosting =
            (panel.shouldUseLocalInlineDeveloperToolsHosting() &&
             isCurrentPaneOwner) ||
            canvasInlineBrowserHosting

        return Group {
            if panel.shouldRenderWebView {
                WebViewRepresentable(
                    panel: panel,
                    paneId: paneId,
                    shouldAttachWebView: isVisibleInUI && isCurrentPaneOwner && !useLocalInlineDeveloperToolsHosting,
                    useLocalInlineHosting: useLocalInlineDeveloperToolsHosting,
                    shouldFocusWebView: isFocused && !addressBarFocused,
                    isPanelFocused: isFocused,
                    portalZPriority: portalPriority,
                    paneDropZone: paneDropZone,
                    searchOverlay: panel.searchState.map { searchState in
                        BrowserPortalSearchOverlayConfiguration(
                            panelId: panel.id,
                            searchState: searchState,
                            focusRequestGeneration: panel.searchFocusRequestGeneration,
                            canApplyFocusRequest: { generation in
                                canApplyBrowserFindFieldFocusRequest(generation)
                            },
                            onNext: { panel.findNext() },
                            onPrevious: { panel.findPrevious() },
                            onClose: { panel.hideFind() },
                            onFieldDidFocus: { panel.noteFindFieldFocused() }
                        )
                    },
                    omnibarSuggestions: portalOmnibarSuggestions,
                    paneTopChromeHeight: panel.isOmnibarVisible ? addressBarHeight : 0
                )
                .accessibilityIdentifier("BrowserWebViewSurface")
                // Keep the host stable for normal pane churn, but force a remount when
                // BrowserPanel replaces its underlying WKWebView after process termination
                // or when the browser moves to a different Bonsplit pane host.
                .id("\(panel.webViewInstanceID.uuidString)-\(paneId.id.uuidString)")
                .contentShape(Rectangle())
                .accessibilityIdentifier(browserContentAccessibilityIdentifier)
                .simultaneousGesture(TapGesture().onEnded {
                    // Chrome-like behavior: clicking web content while editing the
                    // omnibar should commit blur and revert transient edits.
                    if addressBarFocused {
#if DEBUG
                        logBrowserFocusState(event: "webContent.tapBlur")
#endif
                        setAddressBarFocused(false, reason: "webContent.tapBlur")
                    }
                })
            } else {
                Color(nsColor: browserChromeBackgroundColor)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier(browserContentAccessibilityIdentifier)
                    .onTapGesture {
                        onRequestPanelFocus()
                        if addressBarFocused {
                            setAddressBarFocused(false, reason: "placeholderContent.tapBlur")
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if shouldShowEmptyStateImportOverlay,
                           browserImportHintPresentation.blankTabPlacement == .inlineStrip {
                            emptyBrowserStateInlineStrip
                        }
                    }
                    .overlay {
                        if shouldShowEmptyStateImportOverlay,
                           browserImportHintPresentation.blankTabPlacement == .floatingCard {
                            emptyBrowserStateCardOverlay
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if panel.hasRecoverableWebContentTermination {
                webContentRecoveryOverlay
            }
        }
        .layoutPriority(1)
        .zIndex(0)
    }

    private var webContentRecoveryOverlay: some View {
        ZStack {
            Color(nsColor: browserChromeBackgroundColor)
                .opacity(0.92)
            Button(action: {
                panel.recoverTerminatedWebContent(reason: "overlayButton")
            }) {
                Label(
                    String(localized: "browser.error.reload", defaultValue: "Reload"),
                    systemImage: "arrow.clockwise"
                )
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .safeHelp(String(localized: "browser.reload", defaultValue: "Reload"))
            .accessibilityIdentifier("BrowserWebContentRecoveryButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }

    private func refreshBrowserChromeStyle() {
        browserChromeStyle = BrowserChromeStyle.resolve(
            for: colorScheme,
            themeBackgroundColor: GhosttyBackgroundTheme.currentColor(),
            drawsBackground: panel.drawsConfiguredWebViewBackgroundForCurrentPage()
        )
    }

    private func syncWebViewResponderPolicyWithViewState(
        reason: String,
        isPanelFocusedOverride: Bool? = nil
    ) {
        guard let cmuxWebView = panel.webView as? CmuxWebView else { return }
        let isPanelFocused = isPanelFocusedOverride ?? isFocused
        let next = isPanelFocused && !panel.shouldSuppressWebViewFocus()
        if cmuxWebView.allowsFirstResponderAcquisition != next {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.policy.resync panel=\(panel.id.uuidString.prefix(5)) " +
                "web=\(ObjectIdentifier(cmuxWebView)) old=\(cmuxWebView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "new=\(next ? 1 : 0) reason=\(reason) " +
                "panelFocusedUsed=\(isPanelFocused ? 1 : 0)"
            )
#endif
        }
        cmuxWebView.allowsFirstResponderAcquisition = next
    }

    private func canHandleOmnibarSelectionNavigation() -> Bool {
        if addressBarFocused {
            return true
        }
        if AppDelegate.shared?.focusedBrowserAddressBarPanelId() == panel.id {
            return true
        }
        let fieldWindow = panel.webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let field = browserOmnibarField(panelId: panel.id, in: fieldWindow),
           field.currentEditor() != nil {
            return true
        }
        return false
    }

    private func canHandleOmnibarSuggestionInteraction() -> Bool {
        canHandleOmnibarSelectionNavigation() && hasActionableOmnibarSuggestions
    }

    private func setAddressBarFocused(
        _ focused: Bool,
        reason: String,
        focusGainedSelectionIntent: BrowserAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
    ) {
#if DEBUG
        if addressBarFocused == focused {
            logBrowserFocusState(
                event: "addressBarFocus.write.noop",
                detail: "reason=\(reason) value=\(focused ? 1 : 0)"
            )
        } else {
            logBrowserFocusState(
                event: "addressBarFocus.write",
                detail: "reason=\(reason) old=\(addressBarFocused ? 1 : 0) new=\(focused ? 1 : 0)"
            )
        }
#endif
        if focused, !addressBarFocused {
            pendingFocusGainedSelectionIntent = focusGainedSelectionIntent
        } else if !focused {
            pendingFocusGainedSelectionIntent = .preserveFieldEditorSelection
        }
        addressBarFocused = focused
        if focused {
            panel.noteAddressBarFocused()
        }
    }

    private func browserFocusResponderChainContains(
        _ start: NSResponder?,
        target: NSResponder
    ) -> Bool {
        var current = start
        var hops = 0
        while let responder = current, hops < 64 {
            if responder === target { return true }
            current = responder.nextResponder
            hops += 1
        }
        return false
    }

    private func isPanelFocusedInModel() -> Bool {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId),
              manager.selectedTabId == panel.workspaceId,
              let workspace = manager.tabs.first(where: { $0.id == panel.workspaceId }) else {
            return false
        }
        return workspace.focusedPanelId == panel.id
    }

    private func canApplyBrowserFindFieldFocusRequest(_ generation: UInt64) -> Bool {
        isPanelFocusedInModel() && panel.canApplySearchFocusRequest(generation)
    }

    private func shouldApplyAddressBarExitFallback(in window: NSWindow) -> Bool {
        // Navigation-triggered omnibar blur can still be unwinding when Cmd+F opens
        // the browser find bar. Once find is visible, any delayed omnibar-exit
        // handoff must not reclaim first responder for WebKit.
        panel.webView.window === window &&
            isPanelFocusedInModel() &&
            panel.searchState == nil
    }

#if DEBUG
    private func browserFocusWindow() -> NSWindow? {
        panel.webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func browserFocusResponderDescription(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return String(describing: type(of: responder))
    }

    private func logBrowserFocusState(event: String, detail: String = "") {
        let window = browserFocusWindow()
        let firstResponder = window?.firstResponder
        let firstResponderType = browserFocusResponderDescription(firstResponder)
        let webResponder = browserFocusResponderChainContains(firstResponder, target: panel.webView) ? 1 : 0
        var line =
            "browser.focus.trace event=\(event) panel=\(panel.id.uuidString.prefix(5)) " +
            "panelFocused=\(isFocused ? 1 : 0) addrFocused=\(addressBarFocused ? 1 : 0) " +
            "suppressWeb=\(panel.shouldSuppressWebViewFocus() ? 1 : 0) " +
            "suppressAuto=\(panel.shouldSuppressOmnibarAutofocus() ? 1 : 0) " +
            "webResponder=\(webResponder) win=\(window?.windowNumber ?? -1) fr=\(firstResponderType)"
        if let pending = panel.pendingAddressBarFocusRequestId {
            line += " pending=\(pending.uuidString.prefix(8))"
        }
        if !detail.isEmpty {
            line += " \(detail)"
        }
        cmuxDebugLog(line)
    }
#endif

    private func syncURLFromPanel() {
        let urlString = panel.preferredURLStringForOmnibar() ?? ""
        let effects = omnibarState.reduce(.panelURLChanged(currentURLString: urlString))
        applyOmnibarEffects(effects)
    }

    private func isCommandPaletteVisibleForPanelWindow() -> Bool {
        guard let app = AppDelegate.shared else { return false }

        if let window = panel.webView.window, app.isCommandPaletteVisible(for: window) {
            return true
        }

        if let manager = app.tabManagerFor(tabId: panel.workspaceId),
           let windowId = app.windowId(for: manager),
           let window = app.mainWindow(for: windowId),
           app.isCommandPaletteVisible(for: window) {
            return true
        }

        if let keyWindow = NSApp.keyWindow, app.isCommandPaletteVisible(for: keyWindow) {
            return true
        }
        if let mainWindow = NSApp.mainWindow, app.isCommandPaletteVisible(for: mainWindow) {
            return true
        }
        return false
    }

    private func commandPaletteVisibilityNotificationMatchesPanelWindow(_ notification: Notification) -> Bool {
        if let notificationWindow = notification.object as? NSWindow,
           panel.webView.window === notificationWindow {
            return true
        }

        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId),
              let panelWindowId = app.windowId(for: manager) else {
            return false
        }

        if let notificationWindowId = notification.userInfo?["windowId"] as? UUID {
            return notificationWindowId == panelWindowId
        }

        if let notificationWindow = notification.object as? NSWindow,
           let panelWindow = app.mainWindow(for: panelWindowId) {
            return notificationWindow === panelWindow
        }
        return false
    }

    private func applyPendingAddressBarFocusRequestIfNeeded() {
        guard let requestId = panel.pendingAddressBarFocusRequestId else {
            return
        }
        guard panel.panelType == .browser else {
            lastHandledAddressBarFocusRequestId = requestId
            panel.acknowledgeAddressBarFocusRequest(requestId)
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply.skip",
                detail: "reason=chrome_hidden request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return
        }
        guard !isCommandPaletteVisibleForPanelWindow() else {
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply.skip",
                detail: "reason=command_palette_visible request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return
        }
        guard lastHandledAddressBarFocusRequestId != requestId else {
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply.skip",
                detail: "reason=already_handled request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return
        }
        lastHandledAddressBarFocusRequestId = requestId
        let selectionIntent = panel.pendingAddressBarFocusSelectionIntent
        panel.beginSuppressWebViewFocusForAddressBar()
#if DEBUG
        logBrowserFocusState(
            event: "addressBarFocus.request.apply",
            detail: "request=\(requestId.uuidString.prefix(8)) selection=\(String(describing: selectionIntent))"
        )
#endif

        if addressBarFocused {
            // Re-run explicit selection behavior only for requests that own it
            // (Cmd+L), without replacing a caret from focus restoration.
            let effects = omnibarState.reduce(.focusReasserted(
                    shouldSelectAll: browserOmnibarShouldSelectAllOnFocusReassertion(
                        selectionIntent: selectionIntent
                    )
                )
            )
            applyOmnibarEffects(effects)
            refreshInlineCompletion()
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply",
                detail: "request=\(requestId.uuidString.prefix(8)) mode=refresh"
            )
#endif
        } else {
            setAddressBarFocused(
                true,
                reason: "request.apply",
                focusGainedSelectionIntent: selectionIntent
            )
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply",
                detail: "request=\(requestId.uuidString.prefix(8)) mode=set_focused"
            )
#endif
        }

        panel.acknowledgeAddressBarFocusRequest(requestId)
#if DEBUG
        logBrowserFocusState(
            event: "addressBarFocus.request.ack",
            detail: "request=\(requestId.uuidString.prefix(8))"
        )
#endif
    }

    private var emptyBrowserStateCardOverlay: some View {
        VStack {
            Spacer(minLength: 22)

            browserImportHintBody
            .padding(12)
            .frame(maxWidth: 360, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
                    Color(nsColor: .separatorColor).opacity(0.45),
                    lineWidth: 1
                )
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)

            Spacer()
        }
        .padding(.horizontal, 18)
    }

    private var emptyBrowserStateInlineStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            browserImportHintBody
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: 520, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.84))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
                        Color(nsColor: .separatorColor).opacity(0.35),
                        lineWidth: 1
                    )
                )
                .shadow(color: Color.black.opacity(0.05), radius: 6, y: 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var browserImportHintPopover: some View {
        browserImportHintBody
            .padding(12)
            .frame(width: 300, alignment: .leading)
    }

    private var browserImportHintBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.import.hint.title", defaultValue: "Import browser data"))
                .font(.system(size: 12.5, weight: .semibold))

            Text(browserImportHintSummary)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "browser.import.hint.settingsFootnote", defaultValue: "You can always find this in Settings > Browser."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    browserImportHintPrimaryButton
                    browserImportHintSettingsButton
                    browserImportHintDismissButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    browserImportHintPrimaryButton
                    HStack(spacing: 10) {
                        browserImportHintSettingsButton
                        browserImportHintDismissButton
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var browserImportHintPrimaryButton: some View {
        Button(String(localized: "browser.import.hint.import", defaultValue: "Import…")) {
            presentImportDialogFromHint()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintImportButton")
    }

    private var browserImportHintSettingsButton: some View {
        Button(String(localized: "browser.import.hint.settings", defaultValue: "Browser Settings")) {
            openBrowserImportSettings()
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintSettingsButton")
    }

    private var browserImportHintDismissButton: some View {
        Button(String(localized: "browser.import.hint.dismiss", defaultValue: "Hide Hint")) {
            dismissBrowserImportHint()
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintDismissButton")
    }

    private var shouldShowEmptyStateImportOverlay: Bool {
        panel.isShowingNewTabPage
    }

    private func presentImportDialogFromHint() {
        isBrowserImportHintPopoverPresented = false
        DispatchQueue.main.async {
            BrowserDataImportCoordinator.shared.presentImportDialog(
                defaultDestinationProfileID: panel.profileID
            )
        }
    }

    private func presentImportDialogFromProfileMenu() {
        isBrowserProfileMenuPresented = false
        DispatchQueue.main.async {
            BrowserDataImportCoordinator.shared.presentImportDialog(
                defaultDestinationProfileID: panel.profileID
            )
        }
    }

    private func openBrowserImportSettings() {
        isBrowserImportHintPopoverPresented = false
        SettingsWindowPresenter.show(
            navigationTarget: .browserImport,
            openWindowOverride: { openWindow(id: SettingsWindowPresenter.windowID) }
        )
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    private func dismissBrowserImportHint() {
        showBrowserImportHintOnBlankTabs = false
        isBrowserImportHintDismissed = true
        isBrowserImportHintPopoverPresented = false
    }

    /// Treat content as blank only if neither WebKit nor the panel model has a nonblank URL.
    private func isBrowserContentBlankForOmnibar() -> Bool {
        panel.preferredURLStringForOmnibar() == nil
    }

    private func autoFocusOmnibarIfBlank() {
        guard panel.isOmnibarVisible else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=omnibar_hidden")
#endif
            return
        }
        guard isFocused else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=panel_not_focused")
#endif
            return
        }
        guard !addressBarFocused else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=already_focused")
#endif
            return
        }
        guard !isCommandPaletteVisibleForPanelWindow() else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=command_palette_visible")
#endif
            return
        }
        // If a test/automation explicitly focused WebKit, don't steal focus back.
        guard !panel.shouldSuppressOmnibarAutofocus() else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=autofocus_suppressed")
#endif
            return
        }
        // If a real navigation is underway (e.g. open_browser https://...), don't steal focus.
        guard !panel.webView.isLoading else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=webview_loading")
#endif
            return
        }
        guard isBrowserContentBlankForOmnibar() else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=webview_not_blank")
#endif
            return
        }
        setAddressBarFocused(true, reason: "autoFocus.blank")
#if DEBUG
        logBrowserFocusState(event: "addressBarFocus.autoFocus.apply")
#endif
    }

    private func refreshEmptyStateImportBrowsers() {
        emptyStateImportBrowserRefreshTask?.cancel()
        emptyStateImportBrowserRefreshGeneration &+= 1
        let generation = emptyStateImportBrowserRefreshGeneration

        guard shouldShowEmptyStateImportOverlay else {
            emptyStateImportBrowsers = []
            emptyStateImportBrowserRefreshTask = nil
            return
        }

        let detector = installedBrowserDetector
        emptyStateImportBrowserRefreshTask = Task {
            let browsers = await Task.detached(priority: .utility) {
                detector.detectInstalledBrowsers()
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard emptyStateImportBrowserRefreshGeneration == generation,
                      shouldShowEmptyStateImportOverlay else { return }
                emptyStateImportBrowsers = browsers
                emptyStateImportBrowserRefreshTask = nil
            }
        }
    }

    private func openDevTools() {
        #if DEBUG
        cmuxDebugLog("browser.toggleDevTools panel=\(panel.id.uuidString.prefix(5))")
        #endif
        if !panel.toggleDeveloperTools() {
            NSSound.beep()
        }
    }

    private func applyBrowserThemeModeSelection(_ mode: BrowserThemeMode) {
        if browserThemeModeRaw != mode.rawValue {
            browserThemeModeRaw = mode.rawValue
        }
        panel.setBrowserThemeMode(mode)
    }

    private func handleOmnibarTap() {
#if DEBUG
        logBrowserFocusState(event: "addressBar.tap")
#endif
        let wasAddressBarFocused = addressBarFocused
        let shouldRequestPanelFocus = !isFocused
        if !wasAddressBarFocused {
            // Mark focused before pane selection converges so WebKit focus is not
            // briefly re-acquired during `focusPane`.
            setAddressBarFocused(true, reason: "omnibar.tap")
        }
        if shouldRequestPanelFocus && wasAddressBarFocused {
            onRequestPanelFocus()
        }
    }

    private func hideSuggestions() {
        cancelPendingOmnibarSuggestionWork()
        let effects = omnibarState.reduce(.suggestionsUpdated([]))
        applyOmnibarEffects(effects)
        inlineCompletion = nil
    }

    private func startOmnibarSuggestionRefreshConsumer() {
        guard omnibarSuggestionRefreshConsumerTask == nil else { return }
        let scheduler = omnibarSuggestionRefreshScheduler
        omnibarSuggestionRefreshConsumerTask = Task { @MainActor in
            for await generation in scheduler.refreshStream {
                guard scheduler.shouldProcessRefresh(generation) else { continue }
                refreshSuggestions()
            }
        }
    }

    private func stopOmnibarSuggestionRefreshConsumer() {
        omnibarSuggestionRefreshConsumerTask?.cancel()
        omnibarSuggestionRefreshConsumerTask = nil
    }

    private func cancelPendingOmnibarSuggestionWork() {
        omnibarSuggestionRefreshScheduler.cancelPendingRefresh()
        suggestionTask?.cancel()
        suggestionTask = nil
        isLoadingRemoteSuggestions = false
    }

    private func handleOmnibarSubmit(liveField: OmnibarLiveFieldSnapshot?) {
        let decision = omnibarSubmitDecision(
            liveField: liveField,
            state: omnibarState,
            inlineCompletion: inlineCompletion,
            canInteractWithSuggestions: canHandleOmnibarSuggestionInteraction()
        )
        switch decision {
        case .commitSelectedSuggestion:
            commitSelectedSuggestion()
        case .navigate(let text):
            if text != omnibarState.buffer {
                // Reconcile the reducer with the live field before navigating so
                // blur and URL-change handling see the text that was submitted.
                let effects = omnibarState.reduce(.bufferChanged(text))
                applyOmnibarEffects(effects)
            }
            panel.navigateSmart(text)
            hideSuggestions()
            suppressNextFocusLostRevert = true
            setAddressBarFocused(false, reason: "omnibar.submit.navigate")
        }
    }

    private func commitSelectedSuggestion() {
        let idx = omnibarState.selectedSuggestionIndex
        guard idx >= 0, idx < omnibarState.suggestions.count else { return }
        commitSuggestion(omnibarState.suggestions[idx])
    }

    private func commitSuggestion(_ suggestion: OmnibarSuggestion) {
        // Treat this as a commit, not a user edit: don't refetch suggestions while we're navigating away.
        omnibarState.buffer = suggestion.completion
        omnibarState.isUserEditing = false
        switch suggestion.kind {
        case .switchToTab(let tabId, let panelId, _, _):
            AppDelegate.shared?.tabManager?.focusTab(tabId, surfaceId: panelId)
        default:
            panel.navigateSmart(suggestion.completion)
        }
        hideSuggestions()
        inlineCompletion = nil
        suppressNextFocusLostRevert = true
        setAddressBarFocused(false, reason: "suggestion.commit")
    }

    private func handleOmnibarEscape() {
        guard addressBarFocused else { return }

        // Chrome-like flow: clear inline completion first, then apply normal escape behavior.
        if inlineCompletion != nil {
            inlineCompletion = nil
            return
        }

        let effects = omnibarState.reduce(.escape)
        applyOmnibarEffects(effects)
        refreshInlineCompletion()
    }

    private func handleOmnibarSelectionChange(range: NSRange, hasMarkedText: Bool) {
        let didBeginComposition = !omnibarHasMarkedText && hasMarkedText
        omnibarSelectionRange = range
        omnibarHasMarkedText = hasMarkedText
        if didBeginComposition {
            hideSuggestions()
        } else {
            // Do not refresh suggestions from selection-state publication. On
            // composition end, the committed buffer change immediately follows.
            refreshInlineCompletion()
        }
    }

    private func acceptInlineCompletion() {
        guard let completion = inlineCompletion else { return }
        let effects = omnibarState.reduce(.bufferChanged(completion.displayText))
        applyOmnibarEffects(effects)
        inlineCompletion = nil
    }

    private func handleInlineBackspace() {
        guard let completion = inlineCompletion else { return }
        let prefix = completion.typedText
        guard !prefix.isEmpty else { return }
        let updated = String(prefix.dropLast())
        let effects = omnibarState.reduce(.bufferChanged(updated))
        applyOmnibarEffects(effects)
        omnibarSelectionRange = NSRange(location: updated.utf16.count, length: 0)
        if !effects.shouldClearInlineCompletion {
            refreshInlineCompletion()
        }
    }

    private func handleInlineClearTypedPrefix() {
        guard inlineCompletion != nil else { return }
        // Modified Backspace dismisses the current inline suggestion instead of
        // refetching suggestions for the shorter prefix.
        _ = omnibarState.reduce(.bufferChanged(""))
        omnibarSelectionRange = NSRange(location: 0, length: 0)
        hideSuggestions()
    }

    private func handleInlineDeleteWordBackward() {
        guard let completion = inlineCompletion else { return }
        let updated = omnibarPrefixAfterDeletingTrailingWord(from: completion.typedText)
        // Modified Backspace dismisses the current inline suggestion instead of
        // refetching suggestions for the shorter prefix.
        _ = omnibarState.reduce(.bufferChanged(updated))
        omnibarSelectionRange = NSRange(location: updated.utf16.count, length: 0)
        hideSuggestions()
    }

    private func deleteSelectedSuggestionIfPossible() {
        let idx = omnibarState.selectedSuggestionIndex
        guard idx >= 0, idx < omnibarState.suggestions.count else { return }

        let target = omnibarState.suggestions[idx]
        guard case .history(let url, _) = target.kind else { return }
        guard panel.historyStore.removeHistoryEntry(urlString: url) else { return }
        refreshSuggestions()
    }

    private func applyBrowserProfileSelection(_ profileID: UUID) {
        isBrowserProfileMenuPresented = false
        let didApply = panel.profileID == profileID || panel.switchToProfile(profileID)
        guard didApply else { return }
        owningWorkspace?.setPreferredBrowserProfileID(profileID)
    }

    private func presentCreateBrowserProfilePrompt() {
        let alert = NSAlert()
        alert.messageText = String(localized: "browser.profile.new.title", defaultValue: "New Browser Profile")
        alert.informativeText = String(localized: "browser.profile.new.message", defaultValue: "Create a separate browser profile for cookies, history, and local storage.")

        let input = NSTextField(string: "")
        input.placeholderString = String(localized: "browser.profile.new.placeholder", defaultValue: "Profile name")
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = input

        alert.addButton(withTitle: String(localized: "common.create", defaultValue: "Create"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        guard alert.runModal() == .alertFirstButtonReturn,
              let profile = browserProfileStore.createProfile(named: input.stringValue) else {
            return
        }

        applyBrowserProfileSelection(profile.id)
    }

    private func presentRenameBrowserProfilePrompt() {
        guard let profile = browserProfileStore.profileDefinition(id: panel.profileID),
              browserProfileStore.canRenameProfile(id: profile.id) else {
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "browser.profile.rename.title", defaultValue: "Rename Browser Profile")
        alert.informativeText = String(localized: "browser.profile.rename.message", defaultValue: "Choose a new name for this browser profile.")

        let input = NSTextField(string: profile.displayName)
        input.placeholderString = String(localized: "browser.profile.new.placeholder", defaultValue: "Profile name")
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = input

        alert.addButton(withTitle: String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = browserProfileStore.renameProfile(id: profile.id, to: input.stringValue)
    }

    private func refreshInlineCompletion() {
        inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: omnibarState.buffer,
            suggestions: omnibarState.suggestions,
            isFocused: addressBarFocused,
            selectionRange: omnibarSelectionRange,
            hasMarkedText: omnibarHasMarkedText
        )
    }

    private func refreshSuggestions() {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            let trimmedQuery = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            CmuxTypingTiming.logDuration(
                path: "browser.omnibar.refreshSuggestions",
                startedAt: typingTimingStart,
                extra: "focused=\(addressBarFocused ? 1 : 0) queryLen=\(trimmedQuery.utf8.count) suggestionCount=\(omnibarState.suggestions.count)"
            )
        }
#endif
        suggestionTask?.cancel()
        suggestionTask = nil
        isLoadingRemoteSuggestions = false

        guard addressBarFocused, !omnibarHasMarkedText else {
#if DEBUG
            cmuxDebugLog(
                "browser.omnibar.suggestions refresh=skip " +
                "panel=\(panel.id.uuidString.prefix(5)) " +
                "focused=\(addressBarFocused ? 1 : 0) marked=\(omnibarHasMarkedText ? 1 : 0) " +
                "bufferLen=\(omnibarState.buffer.utf8.count)"
            )
#endif
            let effects = omnibarState.reduce(.suggestionsUpdated([]))
            applyOmnibarEffects(effects)
            return
        }

        let query = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let historyEntries: [BrowserHistoryStore.Entry] = {
            if query.isEmpty {
                return panel.historyStore.recentSuggestions(limit: 12)
            }
            return panel.historyStore.suggestions(for: query, limit: 12)
        }()
        let openTabMatches = query.isEmpty ? [] : matchingOpenTabSuggestions(for: query, limit: 12)
        let isSingleCharacterQuery = omnibarSingleCharacterQuery(for: query) != nil
        let remoteSuggestionsEngine = searchConfiguration.remoteSuggestionsEngine
        let allowsRemoteSuggestions = remoteSuggestionsEnabled && remoteSuggestionsEngine != nil
        if !allowsRemoteSuggestions {
            latestRemoteSuggestionQuery = ""
            latestRemoteSuggestions = []
        }
        let staleRemote: [String]
        if query.isEmpty || isSingleCharacterQuery {
            staleRemote = []
        } else {
            staleRemote = staleRemoteSuggestionsForDisplay(
                query: query,
                allowsRemoteSuggestions: allowsRemoteSuggestions
            )
        }
        let resolvedURL = query.isEmpty ? nil : panel.resolveNavigableURL(from: query)
        let items = buildOmnibarSuggestions(
            query: query,
            engineName: searchConfiguration.displayName,
            historyEntries: historyEntries,
            openTabMatches: openTabMatches,
            remoteQueries: staleRemote,
            resolvedURL: resolvedURL,
            limit: 8
        )
        let effects = omnibarState.reduce(.suggestionsUpdated(items))
        applyOmnibarEffects(effects)
        refreshInlineCompletion()
#if DEBUG
        cmuxDebugLog(
            "browser.omnibar.suggestions refresh=local " +
            "panel=\(panel.id.uuidString.prefix(5)) queryLen=\(query.utf8.count) " +
            "items=\(items.count) history=\(historyEntries.count) openTabs=\(openTabMatches.count) " +
            "staleRemote=\(staleRemote.count) frameWidth=\(String(format: "%.1f", omnibarPillFrame.width)) " +
            "portal=\(shouldRenderOmnibarSuggestionsInPortal ? 1 : 0)"
        )
#endif

        guard !query.isEmpty else { return }

        if !isSingleCharacterQuery, let forcedRemote = forcedRemoteSuggestionsForUITest() {
            latestRemoteSuggestionQuery = query
            latestRemoteSuggestions = forcedRemote
            let merged = buildOmnibarSuggestions(
                query: query,
                engineName: searchConfiguration.displayName,
                historyEntries: historyEntries,
                openTabMatches: openTabMatches,
                remoteQueries: forcedRemote,
                resolvedURL: resolvedURL,
                limit: 8
            )
            let forcedEffects = omnibarState.reduce(.suggestionsUpdated(merged))
            applyOmnibarEffects(forcedEffects)
            refreshInlineCompletion()
#if DEBUG
            cmuxDebugLog(
                "browser.omnibar.suggestions refresh=forcedRemote " +
                "panel=\(panel.id.uuidString.prefix(5)) queryLen=\(query.utf8.count) items=\(merged.count)"
            )
#endif
            return
        }

        guard remoteSuggestionsEnabled else { return }
        guard !isSingleCharacterQuery else { return }
        guard omnibarInputIntent(for: query) != .urlLike else { return }

        // Keep current remote rows visible while fetching fresh predictions.
        guard let engine = remoteSuggestionsEngine else { return }
        isLoadingRemoteSuggestions = true
        suggestionTask = Task {
            let remote = await BrowserSearchSuggestionService.shared.suggestions(engine: engine, query: query)
            if Task.isCancelled { return }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard addressBarFocused, !omnibarHasMarkedText else { return }
                let current = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard current == query else { return }
                latestRemoteSuggestionQuery = query
                latestRemoteSuggestions = remote
                let merged = buildOmnibarSuggestions(
                    query: query,
                    engineName: searchConfiguration.displayName,
                    historyEntries: panel.historyStore.suggestions(for: query, limit: 12),
                    openTabMatches: matchingOpenTabSuggestions(for: query, limit: 12),
                    remoteQueries: remote,
                    resolvedURL: panel.resolveNavigableURL(from: query),
                    limit: 8
                )
                let effects = omnibarState.reduce(.suggestionsUpdated(merged))
                applyOmnibarEffects(effects)
                refreshInlineCompletion()
                isLoadingRemoteSuggestions = false
#if DEBUG
                cmuxDebugLog(
                    "browser.omnibar.suggestions refresh=remote " +
                    "panel=\(panel.id.uuidString.prefix(5)) queryLen=\(query.utf8.count) " +
                    "remote=\(remote.count) items=\(merged.count)"
                )
#endif
            }
        }
    }

    private func staleRemoteSuggestionsForDisplay(
        query: String,
        allowsRemoteSuggestions: Bool = true
    ) -> [String] {
        staleOmnibarRemoteSuggestionsForDisplay(
            query: query,
            previousRemoteQuery: latestRemoteSuggestionQuery,
            previousRemoteSuggestions: latestRemoteSuggestions,
            allowsRemoteSuggestions: allowsRemoteSuggestions
        )
    }

    private func matchingOpenTabSuggestions(for query: String, limit: Int) -> [OmnibarOpenTabMatch] {
        guard !query.isEmpty, limit > 0 else { return [] }
        let singleCharacterQuery = omnibarSingleCharacterQuery(for: query)
        let includeCurrentPanelForSingleCharacterQuery = singleCharacterQuery != nil
        let currentPanelSnapshot = BrowserOpenTabSuggestionSnapshot(
            workspaceId: panel.workspaceId,
            panelId: panel.id,
            url: panel.preferredURLStringForOmnibar(),
            title: panel.pageTitle
        )
        let tabManager = AppDelegate.shared?.tabManagerFor(tabId: panel.workspaceId) ?? AppDelegate.shared?.tabManager
        return tabManager?.matchingOpenBrowserTabSuggestions(
            for: query,
            currentWorkspaceId: panel.workspaceId,
            currentPanelId: panel.id,
            currentPanelSnapshot: currentPanelSnapshot,
            includeCurrentPanelForSingleCharacterQuery: includeCurrentPanelForSingleCharacterQuery,
            limit: limit
        ) ?? []
    }

    private func forcedRemoteSuggestionsForUITest() -> [String]? {
        let raw = ProcessInfo.processInfo.environment["CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON"]
            ?? UserDefaults.standard.string(forKey: "CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON")
        guard let raw,
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }

        let values = parsed.compactMap { item -> String? in
            guard let s = item as? String else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return values.isEmpty ? nil : values
    }

    private func applyOmnibarEffects(_ effects: OmnibarEffects) {
        if effects.shouldCancelPendingSuggestionRefresh {
            cancelPendingOmnibarSuggestionWork()
        }
        if effects.shouldClearInlineCompletion {
            inlineCompletion = nil
        }
        if effects.shouldRefreshSuggestions {
            omnibarSuggestionRefreshScheduler.scheduleRefresh()
        }
        if effects.shouldSelectAll {
            omnibarSelectAllRequestId &+= 1
        }
        if effects.shouldBlurToWebView {
            hideSuggestions()
            // This transition is stateful: drop omnibar focus suppression before
            // attempting responder handoff so WKWebView can actually become first responder.
            panel.endSuppressWebViewFocusForAddressBar()
            syncWebViewResponderPolicyWithViewState(reason: "effects.blurToWebView.preHandoff")
            setAddressBarFocused(false, reason: "effects.blurToWebView")
            DispatchQueue.main.async {
                guard let window = panel.webView.window,
                      !panel.webView.isHiddenOrHasHiddenAncestor else { return }
                guard shouldApplyAddressBarExitFallback(in: window) else {
#if DEBUG
                    cmuxDebugLog(
                        "browser.focus.addressBar.exit.handoff panel=\(panel.id.uuidString.prefix(5)) " +
                        "result=skip_not_focused"
                    )
#endif
                    NotificationCenter.default.post(name: .browserDidExitAddressBar, object: panel.id)
                    return
                }
                syncWebViewResponderPolicyWithViewState(reason: "effects.blurToWebView.handoff")
                panel.clearWebViewFocusSuppression()
                let focusedWebView = window.makeFirstResponder(panel.webView)
                if focusedWebView {
                    panel.noteWebViewFocused()
                }
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.addressBar.exit.handoff panel=\(panel.id.uuidString.prefix(5)) " +
                    "focusedWebView=\(focusedWebView ? 1 : 0)"
                )
#endif
                panel.restoreAddressBarPageFocusIfNeeded { restored in
                    guard shouldApplyAddressBarExitFallback(in: window) else {
#if DEBUG
                        cmuxDebugLog(
                            "browser.focus.addressBar.exit.handoff panel=\(panel.id.uuidString.prefix(5)) " +
                            "result=skip_stale_restore restored=\(restored ? 1 : 0)"
                        )
#endif
                        NotificationCenter.default.post(name: .browserDidExitAddressBar, object: panel.id)
                        return
                    }
                    var hasWebViewResponder =
                        browserFocusResponderChainContains(window.firstResponder, target: panel.webView)
                    if !hasWebViewResponder {
                        let fallbackFocusedWebView = window.makeFirstResponder(panel.webView)
                        hasWebViewResponder = fallbackFocusedWebView
#if DEBUG
                        cmuxDebugLog(
                            "browser.focus.addressBar.exit.handoff panel=\(panel.id.uuidString.prefix(5)) " +
                            "fallbackFocusedWebView=\(fallbackFocusedWebView ? 1 : 0) " +
                            "restored=\(restored ? 1 : 0)"
                        )
#endif
                    }
                    if hasWebViewResponder {
                        panel.noteWebViewFocused()
                    }
                    NotificationCenter.default.post(name: .browserDidExitAddressBar, object: panel.id)
                }
            }
        }
    }
}

func omnibarInputIntent(for query: String) -> OmnibarInputIntent {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .ambiguous }

    if resolveBrowserNavigableURL(trimmed) != nil {
        return .urlLike
    }

    if trimmed.contains(" ") {
        return .queryLike
    }

    if trimmed.contains(".") {
        return .ambiguous
    }

    return .queryLike
}

func omnibarSingleCharacterQuery(for query: String) -> String? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.utf16.count == 1 else { return nil }
    return trimmed
}

func omnibarStrippedURL(_ value: String) -> String {
    return value.strippingHTTPSchemeAndWWWPrefix
}

func omnibarScoringCandidate(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    if let components = URLComponents(string: trimmed), let host = components.host?.lowercased() {
        let hostWithoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let normalizedScheme = components.scheme?.lowercased()
        let isDefaultPort = (normalizedScheme == "http" && components.port == 80)
            || (normalizedScheme == "https" && components.port == 443)
        let portSuffix = {
            guard let port = components.port, !isDefaultPort else { return "" }
            return ":\(port)"
        }()

        var normalized = "\(hostWithoutWWW)\(portSuffix)"
        let path = components.percentEncodedPath
        if !path.isEmpty && path != "/" {
            normalized += path
        } else if path == "/" {
            normalized += "/"
        }

        if let query = components.percentEncodedQuery, !query.isEmpty {
            normalized += "?\(query)"
        }
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            normalized += "#\(fragment)"
        }
        return normalized
    }

    return trimmed.strippingHTTPSchemeAndWWWPrefix
}

func omnibarHasSingleCharacterPrefixMatch(query: String, url: String, title: String?) -> Bool {
    guard let trimmedQuery = omnibarSingleCharacterQuery(for: query) else { return false }

    let normalizedURL = omnibarStrippedURL(url).lowercased()
    let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return normalizedURL.hasPrefix(trimmedQuery) || normalizedTitle.hasPrefix(trimmedQuery)
}

func buildOmnibarSuggestions(
    query: String,
    engineName: String,
    historyEntries: [BrowserHistoryStore.Entry],
    openTabMatches: [OmnibarOpenTabMatch] = [],
    remoteQueries: [String],
    resolvedURL: URL?,
    limit: Int = 8,
    now: Date = Date()
) -> [OmnibarSuggestion] {
    guard limit > 0 else { return [] }

    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedQuery.isEmpty {
        return Array(historyEntries.prefix(limit).map { .history($0) })
    }
    let singleCharacterQuery = omnibarSingleCharacterQuery(for: trimmedQuery)
    let isSingleCharacterQuery = singleCharacterQuery != nil
    let shouldIncludeRemoteSuggestions = !isSingleCharacterQuery
    let filteredHistoryEntries: [BrowserHistoryStore.Entry]
    let filteredOpenTabMatches: [OmnibarOpenTabMatch]
    if let singleCharacterQuery {
        filteredHistoryEntries = historyEntries.filter {
            omnibarHasSingleCharacterPrefixMatch(query: singleCharacterQuery, url: $0.url, title: $0.title)
        }
        filteredOpenTabMatches = openTabMatches.filter {
            omnibarHasSingleCharacterPrefixMatch(query: singleCharacterQuery, url: $0.url, title: $0.title)
        }
    } else {
        filteredHistoryEntries = historyEntries
        filteredOpenTabMatches = openTabMatches
    }

    let shouldSuppressSingleCharacterSearchResult = isSingleCharacterQuery
        && (!filteredHistoryEntries.isEmpty || !filteredOpenTabMatches.isEmpty)

    struct RankedSuggestion {
        let suggestion: OmnibarSuggestion
        let score: Double
        let order: Int
        let isAutocompletableMatch: Bool
        let kindPriority: Int
    }

    var bestByCompletion: [String: RankedSuggestion] = [:]
    var order = 0
    let intent = omnibarInputIntent(for: trimmedQuery)
    let normalizedQuery = trimmedQuery.lowercased()

    func suggestionPriority(for kind: OmnibarSuggestion.Kind) -> Int {
        switch kind {
        case .search:
            return 300
        case .remote:
            return 350
        default:
            return 0
        }
    }

    func completionScore(for candidate: String) -> Double {
        let c = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let q = normalizedQuery
        guard !c.isEmpty, !q.isEmpty else { return 0 }

        let scoringCandidate = omnibarScoringCandidate(c)
        if !scoringCandidate.isEmpty {
            if scoringCandidate == q { return 260 }
            if scoringCandidate.hasPrefix(q) { return 220 }
            if scoringCandidate.contains(q) { return 150 }
        }

        if c == q { return 240 }
        if c.hasPrefix(q) { return 170 }
        if c.contains(q) { return 95 }
        return 0
    }

    func insert(_ suggestion: OmnibarSuggestion, score: Double) {
        let key = suggestion.completion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        let isAutocompletableMatch = suggestion.supportsAutocompletion(query: trimmedQuery)

        let ranked = RankedSuggestion(
            suggestion: suggestion,
            score: score,
            order: order,
            isAutocompletableMatch: isAutocompletableMatch,
            kindPriority: suggestionPriority(for: suggestion.kind)
        )
        order += 1
        if let existing = bestByCompletion[key] {
            let shouldReplaceExisting: Bool = {
                // For identical completions, keep "go to URL" over "switch to tab" so
                // pressing Enter performs navigation unless the user explicitly picks a tab row.
                switch (existing.suggestion.kind, ranked.suggestion.kind) {
                case (.navigate, .switchToTab):
                    return false
                case (.switchToTab, .navigate):
                    return true
                default:
                    return ranked.score > existing.score
                }
            }()
            if shouldReplaceExisting {
                bestByCompletion[key] = ranked
            }
        } else {
            bestByCompletion[key] = ranked
        }
    }

    if !(isSingleCharacterQuery && shouldSuppressSingleCharacterSearchResult) {
        let searchBaseScore: Double
        switch intent {
        case .queryLike: searchBaseScore = 820
        case .ambiguous: searchBaseScore = 540
        case .urlLike: searchBaseScore = 140
        }
        insert(.search(engineName: engineName, query: trimmedQuery), score: searchBaseScore + completionScore(for: trimmedQuery))
    }

    if let resolvedURL {
        let completion = resolvedURL.absoluteString
        let navigateBaseScore: Double
        switch intent {
        case .urlLike: navigateBaseScore = 1_020
        case .ambiguous: navigateBaseScore = 760
        case .queryLike: navigateBaseScore = 470
        }
        insert(.navigate(url: completion), score: navigateBaseScore + completionScore(for: completion))
    }

    for (index, entry) in filteredHistoryEntries.prefix(max(limit * 2, limit)).enumerated() {
        let intentBaseScore: Double
        switch intent {
        case .urlLike: intentBaseScore = 780
        case .ambiguous: intentBaseScore = 690
        case .queryLike: intentBaseScore = 600
        }
        let urlMatch = completionScore(for: entry.url)
        let titleMatch = completionScore(for: entry.title ?? "") * 0.6
        let ageHours = max(0, now.timeIntervalSince(entry.lastVisited) / 3600)
        let recencyScore = max(0, 75 - (ageHours / 5))
        let visitScore = min(95, log1p(Double(max(1, entry.visitCount))) * 32)
        let typedScore = min(230, log1p(Double(max(0, entry.typedCount))) * 100)
        let typedRecencyScore: Double
        if let lastTypedAt = entry.lastTypedAt {
            let typedAgeHours = max(0, now.timeIntervalSince(lastTypedAt) / 3600)
            typedRecencyScore = max(0, 80 - (typedAgeHours / 5))
        } else {
            typedRecencyScore = 0
        }
        let positionScore = Double(max(0, 16 - index))
        let total = intentBaseScore + urlMatch + titleMatch + recencyScore + visitScore + typedScore + typedRecencyScore + positionScore
        insert(.history(entry), score: total)
    }

    for (index, match) in filteredOpenTabMatches.prefix(limit).enumerated() {
        let intentBaseScore: Double
        switch intent {
        case .urlLike: intentBaseScore = 1_180
        case .ambiguous: intentBaseScore = 980
        case .queryLike: intentBaseScore = 820
        }
        let urlMatch = completionScore(for: match.url)
        let titleMatch = completionScore(for: match.title ?? "") * 0.65
        let positionScore = Double(max(0, 14 - index)) * 0.9
        let resolvedURLBonus: Double
        if let resolvedURL,
           resolvedURL.absoluteString.caseInsensitiveCompare(match.url) == .orderedSame {
            resolvedURLBonus = 120
        } else {
            resolvedURLBonus = 0
        }
        let total = intentBaseScore + urlMatch + titleMatch + positionScore + resolvedURLBonus
        if match.isKnownOpenTab {
            insert(
                .switchToTab(tabId: match.tabId, panelId: match.panelId, url: match.url, title: match.title),
                score: total
            )
        } else {
            insert(
                OmnibarSuggestion.history(url: match.url, title: match.title),
                score: total
            )
        }
    }

    if shouldIncludeRemoteSuggestions {
        for (index, remoteQuery) in remoteQueries.prefix(limit).enumerated() {
            let trimmedRemote = remoteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRemote.isEmpty else { continue }

            let remoteBaseScore: Double
            switch intent {
            case .queryLike: remoteBaseScore = 690
            case .ambiguous: remoteBaseScore = 450
            case .urlLike: remoteBaseScore = 110
            }
            let positionScore = Double(max(0, 14 - index)) * 0.9
            let total = remoteBaseScore + completionScore(for: trimmedRemote) + positionScore
            insert(.remoteSearchSuggestion(trimmedRemote), score: total)
        }
    }

    let sorted = bestByCompletion.values.sorted { lhs, rhs in
        if lhs.isAutocompletableMatch != rhs.isAutocompletableMatch {
            return lhs.isAutocompletableMatch
        }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.kindPriority != rhs.kindPriority {
            return lhs.kindPriority < rhs.kindPriority
        }
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.suggestion.completion < rhs.suggestion.completion
    }
    let suggestions = Array(sorted.map(\.suggestion).prefix(limit))
    return prioritizedAutocompletionSuggestions(suggestions: Array(suggestions), for: trimmedQuery)
}

private func prioritizedAutocompletionSuggestions(suggestions: [OmnibarSuggestion], for query: String) -> [OmnibarSuggestion] {
    guard let preferred = OmnibarSuggestion.preferredAutocompletionIndex(
        in: suggestions,
        query: query
    ) else {
        return suggestions
    }

    guard preferred != 0 else { return suggestions }

    var reordered = suggestions
    let suggestion = reordered.remove(at: preferred)
    reordered.insert(suggestion, at: 0)
    return reordered
}

func staleOmnibarRemoteSuggestionsForDisplay(
    query: String,
    previousRemoteQuery: String,
    previousRemoteSuggestions: [String],
    allowsRemoteSuggestions: Bool = true,
    limit: Int = 8
) -> [String] {
    guard allowsRemoteSuggestions else { return [] }
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPreviousQuery = previousRemoteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let loweredQuery = trimmedQuery.lowercased()
    let loweredPreviousQuery = trimmedPreviousQuery.lowercased()
    guard !trimmedQuery.isEmpty, !trimmedPreviousQuery.isEmpty else { return [] }
    guard loweredQuery == loweredPreviousQuery || loweredQuery.hasPrefix(loweredPreviousQuery) || loweredPreviousQuery.hasPrefix(loweredQuery) else {
        return []
    }
    guard !previousRemoteSuggestions.isEmpty else { return [] }
    let sanitized = previousRemoteSuggestions.compactMap { raw -> String? in
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    if sanitized.isEmpty {
        return []
    }
    return Array(sanitized.prefix(limit))
}

func omnibarInlineCompletionForDisplay(
    typedText: String,
    suggestions: [OmnibarSuggestion],
    isFocused: Bool,
    selectionRange: NSRange,
    hasMarkedText: Bool
) -> OmnibarInlineCompletion? {
    guard isFocused else { return nil }
    guard !hasMarkedText else { return nil }

    let query = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    let loweredQuery = query.lowercased()
    let typedIncludesScheme = loweredQuery.hasPrefix("https://") || loweredQuery.hasPrefix("http://")
    let typedIncludesWWWPrefix = loweredQuery.hasPrefix("www.")
    let queryCount = query.utf16.count

    let urlCandidate = suggestions.first { suggestion in
        guard let completion = suggestion.autocompletionCompletion else { return false }
        return OmnibarSuggestion.matchesTypedPrefix(
            typedText: query,
            suggestionCompletion: completion,
            suggestionTitle: suggestion.autocompletionTitle
        )
    }
    guard let candidate = urlCandidate else {
        return nil
    }

    let acceptedText = candidate.completion
    let displayText: String
    if typedQueryHasExplicitPathOrQuery(query) {
        if typedIncludesScheme {
            displayText = acceptedText
        } else if typedIncludesWWWPrefix {
            displayText = acceptedText.strippingHTTPSchemePrefix
        } else {
            displayText = acceptedText.strippingHTTPSchemeAndWWWPrefix
        }
    } else if let hostOnlyDisplay = inlineCompletionHostDisplayText(
        for: acceptedText,
        typedIncludesScheme: typedIncludesScheme,
        typedIncludesWWWPrefix: typedIncludesWWWPrefix
    ) {
        displayText = hostOnlyDisplay
    } else {
        if typedIncludesScheme {
            displayText = acceptedText
        } else if typedIncludesWWWPrefix {
            displayText = acceptedText.strippingHTTPSchemePrefix
        } else {
            displayText = acceptedText.strippingHTTPSchemeAndWWWPrefix
        }
    }

    guard candidate.supportsAutocompletion(query: query) else { return nil }
    // The display text must start with the typed query so the inline completion
    // visually extends what the user typed rather than replacing it (e.g. a
    // history entry matched via title "localhost:3000" whose URL is google.com
    // should not replace a typed "l" with "g").
    guard displayText.lowercased().hasPrefix(loweredQuery) else { return nil }
    guard displayText.utf16.count > queryCount else {
        return nil
    }

    let displayCount = displayText.utf16.count

    let resolvedSelectionRange: NSRange = {
        if selectionRange.location == NSNotFound {
            return NSRange(location: queryCount, length: 0)
        }
        let clampedLocation = min(selectionRange.location, displayCount)
        let remaining = max(0, displayCount - clampedLocation)
        let clampedLength = min(selectionRange.length, remaining)
        return NSRange(location: clampedLocation, length: clampedLength)
    }()

    let suffixRange = NSRange(location: queryCount, length: max(0, displayCount - queryCount))
    let isCaretAtTypedBoundary = (resolvedSelectionRange.length == 0 && resolvedSelectionRange.location == queryCount)
    let isSuffixSelection = NSEqualRanges(resolvedSelectionRange, suffixRange)
    let isSelectAllSelection = (resolvedSelectionRange.location == 0 && resolvedSelectionRange.length == displayCount)
    // Command+A can briefly report just the typed prefix selection before the full
    // select-all range lands. Keep inline completion alive through that transition.
    let typedPrefixSelection = NSRange(location: 0, length: queryCount)
    let isTypedPrefixSelection = NSEqualRanges(resolvedSelectionRange, typedPrefixSelection)
    guard isCaretAtTypedBoundary || isSuffixSelection || isSelectAllSelection || isTypedPrefixSelection else {
        return nil
    }

    return OmnibarInlineCompletion(typedText: query, displayText: displayText, acceptedText: acceptedText)
}

func omnibarDesiredSelectionRangeForInlineCompletion(
    currentSelection: NSRange,
    inlineCompletion: OmnibarInlineCompletion
) -> NSRange {
    let typedCount = inlineCompletion.typedText.utf16.count
    let typedPrefixSelection = NSRange(location: 0, length: typedCount)
    let displayCount = inlineCompletion.displayText.utf16.count
    let isSelectAll = currentSelection.location == 0 && currentSelection.length == displayCount
    if isSelectAll ||
        NSEqualRanges(currentSelection, inlineCompletion.suffixRange) ||
        NSEqualRanges(currentSelection, typedPrefixSelection) {
        return currentSelection
    }
    return inlineCompletion.suffixRange
}

func omnibarPublishedBufferTextForFieldChange(
    fieldValue: String,
    inlineCompletion: OmnibarInlineCompletion?,
    selectionRange: NSRange?,
    hasMarkedText: Bool
) -> String {
    guard !hasMarkedText else { return fieldValue }
    guard let inlineCompletion else { return fieldValue }
    guard fieldValue == inlineCompletion.displayText else { return fieldValue }
    guard let selectionRange else { return inlineCompletion.typedText }

    let typedCount = inlineCompletion.typedText.utf16.count
    let displayCount = inlineCompletion.displayText.utf16.count
    let typedPrefixSelection = NSRange(location: 0, length: typedCount)
    let isCaretAtTypedBoundary = selectionRange.location == typedCount && selectionRange.length == 0
    let isSuffixSelection = NSEqualRanges(selectionRange, inlineCompletion.suffixRange)
    let isSelectAllSelection = selectionRange.location == 0 && selectionRange.length == displayCount
    let isTypedPrefixSelection = NSEqualRanges(selectionRange, typedPrefixSelection)
    if isCaretAtTypedBoundary || isSuffixSelection || isSelectAllSelection || isTypedPrefixSelection {
        return inlineCompletion.typedText
    }

    return fieldValue
}

func omnibarInlineCompletionIfBufferMatchesTypedPrefix(
    bufferText: String,
    inlineCompletion: OmnibarInlineCompletion?
) -> OmnibarInlineCompletion? {
    guard let inlineCompletion else { return nil }
    guard bufferText == inlineCompletion.typedText else { return nil }
    return inlineCompletion
}

func omnibarPrefixAfterDeletingTrailingWord(from text: String) -> String {
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    var deletionStart = nsText.length
    nsText.enumerateSubstrings(in: fullRange, options: [.byWords, .reverse]) { _, range, _, stop in
        deletionStart = range.location
        stop.pointee = true
    }
    return nsText.substring(to: deletionStart)
}

private func typedQueryHasExplicitPathOrQuery(_ typedQuery: String) -> Bool {
    var normalized = typedQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("https://") {
        normalized.removeFirst("https://".count)
    } else if normalized.hasPrefix("http://") {
        normalized.removeFirst("http://".count)
    }
    return normalized.contains("/") || normalized.contains("?") || normalized.contains("#")
}

private func inlineCompletionHostDisplayText(
    for acceptedText: String,
    typedIncludesScheme: Bool,
    typedIncludesWWWPrefix: Bool
) -> String? {
    guard let components = URLComponents(string: acceptedText),
          var host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !host.isEmpty else {
        return nil
    }

    if !typedIncludesWWWPrefix, host.hasPrefix("www.") {
        host.removeFirst("www.".count)
    }

    let portSuffix: String
    if let port = components.port {
        let scheme = components.scheme?.lowercased()
        let isDefaultPort =
            (scheme == "https" && port == 443) ||
            (scheme == "http" && port == 80)
        portSuffix = isDefaultPort ? "" : ":\(port)"
    } else {
        portSuffix = ""
    }

    let hostWithPort = "\(host)\(portSuffix)"
    if typedIncludesScheme {
        let scheme = (components.scheme?.lowercased() == "http") ? "http" : "https"
        return "\(scheme)://\(hostWithPort)"
    }
    return hostWithPort
}

private struct OmnibarPillFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct BrowserAddressBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BrowserAddressBarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

func browserOmnibarShouldReacquireFocusAfterEndEditing(
    desiredOmnibarFocus: Bool,
    nextResponderIsOtherTextField: Bool
) -> Bool {
    desiredOmnibarFocus && !nextResponderIsOtherTextField
}

func browserOmnibarShouldSelectAllOnFocusReassertion(
    selectionIntent: BrowserAddressBarFocusSelectionIntent
) -> Bool {
    selectionIntent.shouldSelectAll
}

/// Whether a completed single click that just moved first responder into the
/// omnibar should select the field's entire contents (Chrome/Safari/Arc parity),
/// instead of leaving the caret the field editor placed at the click point.
///
/// The first click on an unfocused omnibar showing a URL selects everything so
/// the user can immediately type a replacement. A subsequent click (the field is
/// already first responder, so `gainedFocusOnThisClick` is `false`) keeps the
/// caret placement from https://github.com/manaflow-ai/cmux/issues/5268. A drag
/// or a Shift-click expresses an explicit range, so select-all defers to it; a
/// double-click never reaches this path (the field routes multi-clicks straight
/// to the field editor for word/line selection, and its second click lands after
/// this click's `mouseUp`, so word selection wins).
///
/// - Parameters:
///   - gainedFocusOnThisClick: `true` when the field had no field editor at
///     `mouseDown`, i.e. this click is the one that moved focus into the omnibar.
///   - isShiftClick: `true` when Shift was held, extending an explicit selection.
///   - didDrag: `true` when the pointer moved far enough to build a drag selection.
/// - Returns: `true` only for an undragged, unmodified focus-gaining click.
func browserOmnibarFocusGainingClickShouldSelectAll(
    gainedFocusOnThisClick: Bool,
    isShiftClick: Bool,
    didDrag: Bool
) -> Bool {
    gainedFocusOnThisClick && !isShiftClick && !didDrag
}

final class OmnibarNativeTextField: NSTextField {
    var panelId: UUID?
    var onPointerDown: (() -> Void)?
    var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?
    var suppressNextFocusReacquireOnEndEditing = false
    /// Anchor index for Shift+click selection extension, reset on non-shift clicks.
    private var shiftClickAnchor: Int?
    private var mouseSelectionState: MouseSelectionState?
    private static let dragSelectionThreshold: CGFloat = 3

    private struct MouseSelectionState {
        let anchor: Int
        let initialWindowLocation: NSPoint
        var didDrag: Bool
        /// `true` when this click moved first responder into the omnibar, gating
        /// the Chrome-style select-all-on-focus behavior applied at `mouseUp`.
        let gainedFocus: Bool
        /// `true` when Shift was held, so an explicit selection extension overrides
        /// the focus-gaining select-all.
        let isShift: Bool
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        let hadEditor = currentEditor() != nil
        onPointerDown?()

        if !hadEditor {
            _ = window?.makeFirstResponder(self)
        }

        guard let editor = currentEditor() as? NSTextView else {
            super.mouseDown(with: event)
            return
        }

        let isShiftClick = event.modifierFlags.contains(.shift)

        // Keep multi-click word and line selection in the field editor, while avoiding
        // NSTextField's mouse tracking loop for ordinary clicks.
        if event.clickCount > 1 {
            mouseSelectionState = nil
            editor.mouseDown(with: event)
            shiftClickAnchor = nil
            return
        }

        let clickIndex = insertionIndex(for: event, in: editor)
        let anchor: Int
        if isShiftClick {
            let selected = editor.selectedRange()
            anchor = shiftClickAnchor ?? selected.location
            shiftClickAnchor = anchor
            setSelection(anchor: anchor, extent: clickIndex, in: editor)
        } else {
            anchor = clickIndex
            shiftClickAnchor = nil
            editor.setSelectedRange(NSRange(location: clickIndex, length: 0))
        }

        mouseSelectionState = MouseSelectionState(
            anchor: anchor,
            initialWindowLocation: event.locationInWindow,
            didDrag: false,
            gainedFocus: !hadEditor,
            isShift: isShiftClick
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard var state = mouseSelectionState,
              let editor = currentEditor() as? NSTextView else {
            super.mouseDragged(with: event)
            return
        }

        let dx = event.locationInWindow.x - state.initialWindowLocation.x
        let dy = event.locationInWindow.y - state.initialWindowLocation.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if state.didDrag || distance >= Self.dragSelectionThreshold {
            state.didDrag = true
            setSelection(anchor: state.anchor, extent: insertionIndex(for: event, in: editor), in: editor)
            mouseSelectionState = state
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let state = mouseSelectionState else {
            super.mouseUp(with: event)
            return
        }
        mouseSelectionState = nil

        // Chrome/Safari/Arc parity: the click that moves first responder into the
        // omnibar selects the whole URL so the next keystroke replaces it. A click
        // while already focused keeps the caret placed in `mouseDown` (issue #5268),
        // and a drag or Shift-click keeps the explicit range built up during the
        // gesture. Double-clicks never reach here — `mouseDown` routes multi-clicks
        // to the field editor for word/line selection and leaves `mouseSelectionState`
        // nil, and the second click lands after this `mouseUp`, so word selection wins.
        // The keyboard path (Cmd+L) still selects all via the `selectAllRequestId` flow.
        guard browserOmnibarFocusGainingClickShouldSelectAll(
            gainedFocusOnThisClick: state.gainedFocus,
            isShiftClick: state.isShift,
            didDrag: state.didDrag
        ), let editor = currentEditor() as? NSTextView else {
            return
        }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
    }

    private func insertionIndex(for event: NSEvent, in editor: NSTextView) -> Int {
        let localPoint = editor.convert(event.locationInWindow, from: nil)
        let index = editor.characterIndexForInsertion(at: localPoint)
        let textLength = (editor.string as NSString).length
        guard index != NSNotFound else { return textLength }
        return min(max(index, 0), textLength)
    }

    private func setSelection(anchor: Int, extent: Int, in editor: NSTextView) {
        if extent >= anchor {
            editor.setSelectedRange(NSRange(location: anchor, length: extent - anchor))
        } else {
            editor.setSelectedRange(NSRange(location: extent, length: anchor - extent))
        }
    }

    override func keyDown(with event: NSEvent) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        var route = "super"
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.omnibar.keyDown",
                startedAt: typingTimingStart,
                event: event,
                extra: "route=\(route)"
            )
        }
#endif
        // Reset shift-click anchor on any keyboard input so that a subsequent
        // Shift+click uses the post-keyboard selection as its anchor, not a
        // stale value from a prior mouse interaction.
        shiftClickAnchor = nil
        mouseSelectionState = nil
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            super.keyDown(with: event)
            return
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
#if DEBUG
            route = "custom"
#endif
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        var handled = false
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.omnibar.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event,
                extra: "handled=\(handled ? 1 : 0)"
            )
        }
#endif
        shiftClickAnchor = nil
        mouseSelectionState = nil
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            let result = super.performKeyEquivalent(with: event)
#if DEBUG
            handled = result
#endif
            return result
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
#if DEBUG
            handled = true
#endif
            return true
        }
        let result = super.performKeyEquivalent(with: event)
#if DEBUG
        handled = result
#endif
        return result
    }
}

struct OmnibarTextFieldRepresentable: NSViewRepresentable {
    let panelId: UUID
    let fontSize: CGFloat
    @Binding var text: String
    @Binding var isFocused: Bool
    let selectAllRequestId: UInt64
    let inlineCompletion: OmnibarInlineCompletion?
    let placeholder: String
    let onTap: () -> Void
    let onSubmit: (OmnibarLiveFieldSnapshot?) -> Void
    let onEscape: () -> Void
    let onFieldLostFocus: () -> Void
    let onMoveSelection: (Int) -> Void
    let onDeleteSelectedSuggestion: () -> Void
    let onAcceptInlineCompletion: () -> Void
    let onDeleteBackwardWithInlineSelection: () -> Void
    let onClearTypedPrefixWithInlineSelection: () -> Void
    let onDeleteWordBackwardWithInlineSelection: () -> Void
    let onSelectionChanged: (NSRange, Bool) -> Void
    let shouldSuppressWebViewFocus: () -> Bool

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmnibarTextFieldRepresentable
        var isProgrammaticMutation: Bool = false
        var selectionObserver: NSObjectProtocol?
        weak var observedEditor: NSTextView?
        var appliedInlineCompletion: OmnibarInlineCompletion?
        var lastPublishedSelection: NSRange = NSRange(location: NSNotFound, length: 0)
        var lastPublishedHasMarkedText: Bool = false
        /// Guards against infinite focus loops: `true` = focus requested, `false` = blur requested, `nil` = idle.
        var pendingFocusRequest: Bool?
        var pendingSelectAllRequestId: UInt64?
        var appliedSelectAllRequestId: UInt64 = 0

        init(parent: OmnibarTextFieldRepresentable) {
            self.parent = parent
        }

#if DEBUG
        func logFocusEvent(_ event: String, detail: String = "") {
            let window = parentField?.window
            let responder = window?.firstResponder
            let responderType = responder.map { String(describing: type(of: $0)) } ?? "nil"
            let responderIsField: Int = {
                guard let field = parentField else { return 0 }
                if responder === field { return 1 }
                if let editor = responder as? NSTextView,
                   (editor.delegate as? NSTextField) === field {
                    return 1
                }
                return 0
            }()
            let pendingValue: String = {
                guard let pendingFocusRequest else { return "nil" }
                return pendingFocusRequest ? "focus" : "blur"
            }()
            var line =
                "browser.focus.field event=\(event) focused=\(parent.isFocused ? 1 : 0) " +
                "pending=\(pendingValue) suppressWeb=\(parent.shouldSuppressWebViewFocus() ? 1 : 0) " +
                "win=\(window?.windowNumber ?? -1) fr=\(responderType) frIsField=\(responderIsField)"
            if !detail.isEmpty {
                line += " \(detail)"
            }
            cmuxDebugLog(line)
        }
#endif

        deinit {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
        }

        private func nextResponderIsOtherTextField(window: NSWindow?) -> Bool {
            guard let window, let field = parentField else { return false }
            let responder = window.firstResponder

            if let editor = responder as? NSTextView,
               let delegateField = editor.delegate as? NSTextField {
                return delegateField !== field
            }

            if let textField = responder as? NSTextField {
                return textField !== field
            }

            return false
        }

        private func isPointerDownEvent(_ event: NSEvent) -> Bool {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                return true
            default:
                return false
            }
        }

        private func topHitViewForCurrentPointerEvent(window: NSWindow) -> NSView? {
            guard let event = NSApp.currentEvent, isPointerDownEvent(event) else {
                return nil
            }
            if event.windowNumber != 0, event.windowNumber != window.windowNumber {
                return nil
            }
            if let eventWindow = event.window, eventWindow !== window {
                return nil
            }

            if let contentView = window.contentView,
               let themeFrame = contentView.superview {
                let pointInTheme = themeFrame.convert(event.locationInWindow, from: nil)
                if let hitInTheme = themeFrame.hitTest(pointInTheme) {
                    return hitInTheme
                }
            }

            guard let contentView = window.contentView else {
                return nil
            }
            let pointInContent = contentView.convert(event.locationInWindow, from: nil)
            return contentView.hitTest(pointInContent)
        }

        private func pointerDownBlurIntent(window: NSWindow?) -> Bool {
            guard let window, let field = parentField else { return false }
            guard let hitView = topHitViewForCurrentPointerEvent(window: window) else {
                return false
            }

            if hitView === field || hitView.isDescendant(of: field) {
                return false
            }
            if let interactionView = hitView as? BrowserOmnibarInteractionView,
               interactionView.panelId == field.panelId {
                return false
            }
            if let textView = hitView as? NSTextView,
               let delegateField = textView.delegate as? NSTextField,
               delegateField === field {
                return false
            }
            return true
        }

        private func shouldReacquireFocusAfterEndEditing(window: NSWindow?) -> Bool {
            if parentField?.suppressNextFocusReacquireOnEndEditing == true {
                return false
            }
            if pointerDownBlurIntent(window: window) {
                return false
            }
            return browserOmnibarShouldReacquireFocusAfterEndEditing(
                desiredOmnibarFocus: parent.isFocused,
                nextResponderIsOtherTextField: nextResponderIsOtherTextField(window: window)
            )
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
#if DEBUG
            logFocusEvent("controlTextDidBeginEditing")
#endif
            if !parent.isFocused {
                DispatchQueue.main.async {
#if DEBUG
                    self.logFocusEvent("controlTextDidBeginEditing.asyncSetFocused", detail: "old=0 new=1")
#endif
                    self.parent.isFocused = true
                }
            }
            attachSelectionObserverIfNeeded()
            if let field = obj.object as? OmnibarNativeTextField {
                field.suppressNextFocusReacquireOnEndEditing = false
                applyPendingSelectAllIfPossible(field: field)
            }
            publishSelectionState()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            let shouldReacquire = shouldReacquireFocusAfterEndEditing(window: parentField?.window)
#if DEBUG
            let nextOther = nextResponderIsOtherTextField(window: parentField?.window)
            let pointerBlur = pointerDownBlurIntent(window: parentField?.window)
            logFocusEvent(
                "controlTextDidEndEditing",
                detail: "nextOther=\(nextOther ? 1 : 0) pointerBlur=\(pointerBlur ? 1 : 0) shouldReacquire=\(shouldReacquire ? 1 : 0)"
            )
#endif
            if parent.isFocused {
                if shouldReacquire {
#if DEBUG
                    logFocusEvent("controlTextDidEndEditing.reacquire.begin")
#endif
                    guard pendingFocusRequest != true else { return }
                    pendingFocusRequest = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.pendingFocusRequest = nil
#if DEBUG
                        self.logFocusEvent("controlTextDidEndEditing.reacquire.tick")
#endif
                        guard self.parent.isFocused else { return }
                        guard let field = self.parentField, let window = field.window else { return }
                        guard self.shouldReacquireFocusAfterEndEditing(window: window) else {
#if DEBUG
                            self.logFocusEvent("controlTextDidEndEditing.reacquire.cancel")
#endif
                            self.parent.onFieldLostFocus()
                            return
                        }
                        // Check both the field itself AND its field editor (which becomes
                        // the actual first responder when the text field is being edited).
                        let fr = window.firstResponder
                        let isAlreadyFocused = fr === field ||
                            field.currentEditor() != nil ||
                            ((fr as? NSTextView)?.delegate as? NSTextField) === field
                        if !isAlreadyFocused {
#if DEBUG
                            self.logFocusEvent("controlTextDidEndEditing.reacquire.apply")
#endif
                            window.makeFirstResponder(field)
                        } else {
#if DEBUG
                            self.logFocusEvent("controlTextDidEndEditing.reacquire.skip", detail: "reason=already_focused")
#endif
                        }
                    }
                    return
                }
#if DEBUG
                logFocusEvent("controlTextDidEndEditing.blur")
#endif
                parent.onFieldLostFocus()
            }
            parentField?.suppressNextFocusReacquireOnEndEditing = false
            detachSelectionObserver()
        }

        func controlTextDidChange(_ obj: Notification) {
#if DEBUG
            let typingTimingStart = CmuxTypingTiming.start()
            defer {
                CmuxTypingTiming.logDuration(
                    path: "browser.omnibar.controlTextDidChange",
                    startedAt: typingTimingStart,
                    event: NSApp.currentEvent,
                    extra: "programmatic=\(isProgrammaticMutation ? 1 : 0)"
                )
            }
#endif
            guard !isProgrammaticMutation else { return }
            guard let field = obj.object as? NSTextField else { return }
            let editor = field.currentEditor() as? NSTextView
            publishSelectionState()
            parent.text = omnibarPublishedBufferTextForFieldChange(
                fieldValue: field.stringValue,
                inlineCompletion: parent.inlineCompletion,
                selectionRange: editor?.selectedRange(),
                hasMarkedText: editor?.hasMarkedText() ?? false
            )
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
#if DEBUG
            let typingTimingStart = CmuxTypingTiming.start()
            var handled = false
            defer {
                CmuxTypingTiming.logDuration(
                    path: "browser.omnibar.doCommandBy",
                    startedAt: typingTimingStart,
                    event: NSApp.currentEvent,
                    extra: "handled=\(handled ? 1 : 0) selector=\(NSStringFromSelector(commandSelector))"
                )
            }
#endif
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(+1)
#if DEBUG
                handled = true
#endif
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
#if DEBUG
                handled = true
#endif
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let currentFlags = NSApp.currentEvent?.modifierFlags ?? []
                guard browserOmnibarShouldSubmitOnReturn(flags: currentFlags) else { return false }
                parent.onSubmit(liveFieldSnapshot(preferredEditor: textView))
#if DEBUG
                handled = true
#endif
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
#if DEBUG
                handled = true
#endif
                return true
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
                if parent.inlineCompletion != nil {
                    parent.onAcceptInlineCompletion()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            case #selector(NSResponder.insertTab(_:)):
                if parent.inlineCompletion != nil {
                    parent.onAcceptInlineCompletion()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            case #selector(NSResponder.deleteBackward(_:)):
                if suffixSelectionMatchesInline(textView, inline: parent.inlineCompletion) {
                    parent.onDeleteBackwardWithInlineSelection()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            case #selector(NSResponder.deleteToBeginningOfLine(_:)),
                 #selector(NSResponder.deleteToBeginningOfParagraph(_:)):
                if inlineCompletionSelectionIsActive(textView, inline: parent.inlineCompletion) {
                    parent.onClearTypedPrefixWithInlineSelection()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            case #selector(NSResponder.deleteWordBackward(_:)):
                if inlineCompletionSelectionIsActive(textView, inline: parent.inlineCompletion) {
                    parent.onDeleteWordBackwardWithInlineSelection()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            default:
                return false
            }
        }

        func attachSelectionObserverIfNeeded() {
            guard selectionObserver == nil else { return }
            guard let field = parentField else { return }
            guard let editor = field.currentEditor() as? NSTextView else { return }
            observedEditor = editor
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: editor,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.publishSelectionState()
                }
            }
        }

        func detachSelectionObserver() {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
                self.selectionObserver = nil
            }
            observedEditor = nil
        }

        weak var parentField: OmnibarNativeTextField?

        func queueSelectAllRequest(_ requestId: UInt64) {
            guard requestId != 0, appliedSelectAllRequestId != requestId else { return }
            pendingSelectAllRequestId = requestId
        }

        @discardableResult
        func applyPendingSelectAllIfPossible(
            field: OmnibarNativeTextField
        ) -> Bool {
            guard let requestId = pendingSelectAllRequestId,
                  requestId != 0,
                  appliedSelectAllRequestId != requestId else {
                return false
            }

            guard let editor = field.currentEditor() as? NSTextView,
                  !editor.hasMarkedText() else {
                return false
            }
            let length = editor.string.utf16.count
            isProgrammaticMutation = true
            editor.setSelectedRange(NSRange(location: 0, length: length))
            isProgrammaticMutation = false
            appliedSelectAllRequestId = requestId
            pendingSelectAllRequestId = nil
            publishSelectionState()
            return true
        }

        func publishSelectionState() {
            guard let field = parentField else { return }
            if let editor = field.currentEditor() as? NSTextView {
                let range = editor.selectedRange()
                let hasMarkedText = editor.hasMarkedText()
                guard !NSEqualRanges(range, lastPublishedSelection) || hasMarkedText != lastPublishedHasMarkedText else {
                    return
                }
                lastPublishedSelection = range
                lastPublishedHasMarkedText = hasMarkedText
                parent.onSelectionChanged(range, hasMarkedText)
            } else {
                let location = field.stringValue.utf16.count
                let range = NSRange(location: location, length: 0)
                guard !NSEqualRanges(range, lastPublishedSelection) || lastPublishedHasMarkedText else { return }
                lastPublishedSelection = range
                lastPublishedHasMarkedText = false
                parent.onSelectionChanged(range, false)
            }
        }

        /// Captures the field-editor text synchronously at submit time. Both
        /// Return interception paths (`doCommandBy` and `handleKeyEvent`) go
        /// through here so the submit decision always starts from what the
        /// field actually shows, not the possibly lagging published state.
        private func liveFieldSnapshot(preferredEditor: NSTextView?) -> OmnibarLiveFieldSnapshot? {
            let editor = preferredEditor ?? (parentField?.currentEditor() as? NSTextView)
            if let editor {
                return OmnibarLiveFieldSnapshot(
                    text: editor.string,
                    selectionRange: editor.selectedRange(),
                    hasMarkedText: editor.hasMarkedText()
                )
            }
            guard let field = parentField else { return nil }
            return OmnibarLiveFieldSnapshot(
                text: field.stringValue,
                selectionRange: nil,
                hasMarkedText: false
            )
        }

        private func inlineCompletionSelectionIsActive(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
            suffixSelectionMatchesInline(editor, inline: inline) || selectionIsTypedPrefixBoundary(editor, inline: inline)
        }

        private func suffixSelectionMatchesInline(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
            guard let editor, let inline else { return false }
            let selected = editor.selectedRange()
            return NSEqualRanges(selected, inline.suffixRange)
        }

        private func selectionIsTypedPrefixBoundary(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
            guard let editor, let inline else { return false }
            let selected = editor.selectedRange()
            let typedCount = inline.typedText.utf16.count
            return selected.location == typedCount && selected.length == 0
        }

        func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
#if DEBUG
            let typingTimingStart = CmuxTypingTiming.start()
            var handled = false
            defer {
                CmuxTypingTiming.logDuration(
                    path: "browser.omnibar.handleKeyEvent",
                    startedAt: typingTimingStart,
                    event: event,
                    extra: "handled=\(handled ? 1 : 0)"
                )
            }
#endif
            guard editor?.hasMarkedText() != true else { return false }
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .control, .shift, .option, .function])
            // When a non-Latin input source is active (Korean, Chinese, Japanese),
            // charactersIgnoringModifiers returns non-ASCII characters. Normalize
            // via KeyboardLayout so Ctrl+N/P navigation works across input sources.
            let lowered = KeyboardLayout.normalizedCharacters(for: event)

            // Ctrl+N and Ctrl+P should repeat while held.
            if let delta = browserOmnibarSelectionDeltaForControlNavigation(
                hasFocusedAddressBar: true,
                flags: event.modifierFlags,
                chars: lowered
            ) {
                parent.onMoveSelection(delta)
#if DEBUG
                handled = true
#endif
                return true
            }

            // Shift+Delete removes the selected history suggestion when possible.
            if modifiers.contains(.shift), (keyCode == 51 || keyCode == 117) {
                parent.onDeleteSelectedSuggestion()
#if DEBUG
                handled = true
#endif
                return true
            }

            switch keyCode {
            case 36, 76: // Return / keypad Enter
                guard browserOmnibarShouldSubmitOnReturn(flags: event.modifierFlags) else { return false }
                parent.onSubmit(liveFieldSnapshot(preferredEditor: editor))
#if DEBUG
                handled = true
#endif
                return true
            case 53: // Escape
                parent.onEscape()
#if DEBUG
                handled = true
#endif
                return true
            case 125: // Down
                parent.onMoveSelection(+1)
#if DEBUG
                handled = true
#endif
                return true
            case 126: // Up
                parent.onMoveSelection(-1)
#if DEBUG
                handled = true
#endif
                return true
            case 124, 119: // Right arrow / End
                if parent.inlineCompletion != nil {
                    parent.onAcceptInlineCompletion()
#if DEBUG
                    handled = true
#endif
                    return true
                }
            case 48: // Tab
                if parent.inlineCompletion != nil {
                    parent.onAcceptInlineCompletion()
#if DEBUG
                    handled = true
#endif
                    return true
                }
            case 51: // Backspace
                if modifiers.contains(.command) || modifiers.contains(.option) {
                    return false
                }
                if let inline = parent.inlineCompletion,
                   inlineCompletionSelectionIsActive(editor, inline: inline) {
                    parent.onDeleteBackwardWithInlineSelection()
#if DEBUG
                    handled = true
#endif
                    return true
                }
            default:
                break
            }

            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> OmnibarNativeTextField {
        let field = OmnibarNativeTextField(frame: .zero)
        field.panelId = panelId
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: panelId)
        field.identifier = browserOmnibarTextFieldIdentifier
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = nil
        field.action = nil
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.stringValue = text
        field.onPointerDown = {
            onTap()
        }
        field.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
            coordinator?.handleKeyEvent(event, editor: editor) ?? false
        }
        context.coordinator.parentField = field
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: panelId)
        return field
    }

    func updateNSView(_ nsView: OmnibarNativeTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.parentField = nsView
        if let previousPanelId = nsView.panelId, previousPanelId != panelId {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(nsView, panelId: previousPanelId)
        }
        nsView.panelId = panelId
        BrowserOmnibarNativeFieldRegistry.shared.register(nsView, panelId: panelId)
        nsView.placeholderString = placeholder
        if nsView.font?.pointSize != fontSize {
            nsView.font = .systemFont(ofSize: fontSize)
        }
        context.coordinator.queueSelectAllRequest(selectAllRequestId)

        let activeInlineCompletion = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: text,
            inlineCompletion: inlineCompletion
        )
        let desiredDisplayText = activeInlineCompletion?.displayText ?? text
        if let editor = nsView.currentEditor() as? NSTextView {
            if !editor.hasMarkedText(), editor.string != desiredDisplayText {
                context.coordinator.isProgrammaticMutation = true
                editor.string = desiredDisplayText
                nsView.stringValue = desiredDisplayText
                context.coordinator.isProgrammaticMutation = false
            }
        } else if nsView.stringValue != desiredDisplayText {
            nsView.stringValue = desiredDisplayText
        }

        if let window = nsView.window {
            let firstResponder = window.firstResponder
            let isFirstResponder =
                firstResponder === nsView ||
                nsView.currentEditor() != nil ||
                ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView
            if isFocused, !isFirstResponder, context.coordinator.pendingFocusRequest != true {
#if DEBUG
                context.coordinator.logFocusEvent(
                    "updateNSView.requestFocus.begin",
                    detail: "isFocused=1 isFirstResponder=0"
                )
#endif
                // Defer to avoid triggering input method XPC during layout pass,
                // which can crash via re-entrant view hierarchy modification.
                context.coordinator.pendingFocusRequest = true
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    coordinator?.pendingFocusRequest = nil
                    guard let nsView, let window = nsView.window else { return }
#if DEBUG
                    if coordinator?.parent.isFocused != true {
                        coordinator?.logFocusEvent("updateNSView.requestFocus.cancel", detail: "reason=stale_state")
                        return
                    }
#endif
                    guard coordinator?.parent.isFocused == true else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestFocus.tick")
#endif
                    let fr = window.firstResponder
                    let alreadyFocused = fr === nsView ||
                        nsView.currentEditor() != nil ||
                        ((fr as? NSTextView)?.delegate as? NSTextField) === nsView
                    if alreadyFocused {
                        coordinator?.applyPendingSelectAllIfPossible(field: nsView)
                        return
                    }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestFocus.apply")
#endif
                    window.makeFirstResponder(nsView)
                    coordinator?.applyPendingSelectAllIfPossible(field: nsView)
                }
            } else if !isFocused, isFirstResponder, context.coordinator.pendingFocusRequest != false {
#if DEBUG
                context.coordinator.logFocusEvent(
                    "updateNSView.requestBlur.begin",
                    detail: "isFocused=0 isFirstResponder=1"
                )
#endif
                context.coordinator.pendingFocusRequest = false
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    coordinator?.pendingFocusRequest = nil
                    guard let nsView, let window = nsView.window else { return }
#if DEBUG
                    if coordinator?.parent.isFocused == true {
                        coordinator?.logFocusEvent("updateNSView.requestBlur.cancel", detail: "reason=stale_state")
                        return
                    }
#endif
                    guard coordinator?.parent.isFocused == false else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestBlur.tick")
#endif
                    let fr = window.firstResponder
                    let stillFirst = fr === nsView ||
                        ((fr as? NSTextView)?.delegate as? NSTextField) === nsView
                    guard stillFirst else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestBlur.apply")
#endif
                    window.makeFirstResponder(nil)
                }
            }
        }
        context.coordinator.applyPendingSelectAllIfPossible(field: nsView)

        if let editor = nsView.currentEditor() as? NSTextView, !editor.hasMarkedText() {
            if let activeInlineCompletion {
                let currentSelection = editor.selectedRange()
                let desiredSelection = omnibarDesiredSelectionRangeForInlineCompletion(
                    currentSelection: currentSelection,
                    inlineCompletion: activeInlineCompletion
                )
                if context.coordinator.appliedInlineCompletion != activeInlineCompletion ||
                    !NSEqualRanges(currentSelection, desiredSelection) {
                    context.coordinator.isProgrammaticMutation = true
                    editor.setSelectedRange(desiredSelection)
                    context.coordinator.isProgrammaticMutation = false
                }
            } else if context.coordinator.appliedInlineCompletion != nil {
                let end = text.utf16.count
                let current = editor.selectedRange()
                if current.length != 0 || current.location != end {
                    context.coordinator.isProgrammaticMutation = true
                    editor.setSelectedRange(NSRange(location: end, length: 0))
                    context.coordinator.isProgrammaticMutation = false
                }
            }
        }
        context.coordinator.appliedInlineCompletion = activeInlineCompletion
        context.coordinator.attachSelectionObserverIfNeeded()
        context.coordinator.publishSelectionState()
    }

    static func dismantleNSView(_ nsView: OmnibarNativeTextField, coordinator: Coordinator) {
        if let panelId = nsView.panelId {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(nsView, panelId: panelId)
        }
        nsView.onPointerDown = nil
        nsView.onHandleKeyEvent = nil
        nsView.delegate = nil
        coordinator.detachSelectionObserver()
        coordinator.parentField = nil
    }
}

@MainActor
func browserOmnibarPanelId(for responder: NSResponder?) -> UUID? {
    browserOmnibarField(for: responder)?.panelId
}

@MainActor
func browserOmnibarField(panelId: UUID?, in window: NSWindow?) -> OmnibarNativeTextField? {
    if let registeredField = BrowserOmnibarNativeFieldRegistry.shared.field(for: panelId, in: window) {
        return registeredField
    }
    guard let panelId, let root = window?.contentView?.superview ?? window?.contentView else {
        return nil
    }

    // Fallback for SwiftUI/AppKit reconnect windows where the live native field
    // has been attached but registration has not yet observed it.
    var stack: [NSView] = [root]
    while let view = stack.popLast() {
        if let field = view as? OmnibarNativeTextField, field.panelId == panelId {
            return field
        }
        stack.append(contentsOf: view.subviews)
    }
    return nil
}

@discardableResult
@MainActor
func browserPrepareOmnibarForProgrammaticBlur(panelId: UUID, responder: NSResponder?) -> Bool {
    guard let field = browserOmnibarField(for: responder),
          field.panelId == panelId else {
        return false
    }
    field.suppressNextFocusReacquireOnEndEditing = true
    return true
}

@MainActor
private func browserOmnibarField(for responder: NSResponder?) -> OmnibarNativeTextField? {
    guard let responder else { return nil }

    if let field = responder as? OmnibarNativeTextField {
        return field
    }

    if let editor = responder as? NSTextView, editor.isFieldEditor {
        if let field = BrowserOmnibarNativeFieldRegistry.shared.fieldOwningEditor(editor, in: editor.window) {
            return field
        }

        if let field = cmuxFieldEditorOwnerView(editor) as? OmnibarNativeTextField,
           field.currentEditor() === editor {
            return field
        }

    }

    return nil
}

struct OmnibarSuggestionsView: View {
    let engineName: String
    let items: [OmnibarSuggestion]
    let selectedIndex: Int
    let isLoadingRemoteSuggestions: Bool
    let searchSuggestionsEnabled: Bool
    let onCommit: (OmnibarSuggestion) -> Void
    let onHighlight: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    // Keep radii below half of the smallest rendered heights so this keeps a
    // squircle silhouette instead of auto-clamping into a capsule.
    private static let popupCornerRadius: CGFloat = 12
    private static let rowHighlightCornerRadius: CGFloat = 9
    private static let singleLineRowHeight: CGFloat = 24
    private static let rowSpacing: CGFloat = 1
    private static let topInset: CGFloat = 3
    private static let bottomInset: CGFloat = 3
    private static let maxPopupHeight: CGFloat = 560

    private var popupCornerRadius: CGFloat { Self.popupCornerRadius }
    private var rowHighlightCornerRadius: CGFloat { Self.rowHighlightCornerRadius }
    private var singleLineRowHeight: CGFloat { Self.singleLineRowHeight }
    private var rowSpacing: CGFloat { Self.rowSpacing }
    private var topInset: CGFloat { Self.topInset }
    private var bottomInset: CGFloat { Self.bottomInset }
    private var horizontalInset: CGFloat { topInset }
    private var maxPopupHeight: CGFloat { Self.maxPopupHeight }

    private var totalRowCount: Int {
        max(1, items.count)
    }

    private func rowHeight(for item: OmnibarSuggestion) -> CGFloat {
        return singleLineRowHeight
    }

    private var contentHeight: CGFloat {
        let rowsHeight = items.isEmpty ? singleLineRowHeight : items.reduce(CGFloat(0)) { partial, item in
            partial + rowHeight(for: item)
        }
        let gaps = CGFloat(max(0, totalRowCount - 1))
        return rowsHeight + (gaps * rowSpacing) + topInset + bottomInset
    }

    private var minimumPopupHeight: CGFloat {
        singleLineRowHeight + topInset + bottomInset
    }

    private func snapToDevicePixels(_ value: CGFloat) -> CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    private var popupHeight: CGFloat {
        Self.popupHeight(for: items)
    }

    static func popupHeight(for items: [OmnibarSuggestion]) -> CGFloat {
        let totalRowCount = max(1, items.count)
        let rowsHeight = items.isEmpty ? singleLineRowHeight : CGFloat(items.count) * singleLineRowHeight
        let gaps = CGFloat(max(0, totalRowCount - 1))
        let contentHeight = rowsHeight + (gaps * rowSpacing) + topInset + bottomInset
        let minimumPopupHeight = singleLineRowHeight + topInset + bottomInset
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let height = min(max(contentHeight, minimumPopupHeight), maxPopupHeight)
        return (height * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    private var isPointerDrivenSelectionEvent: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
             .rightMouseDown, .rightMouseDragged, .rightMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp, .scrollWheel:
            return true
        default:
            return false
        }
    }

    private var shouldScroll: Bool {
        contentHeight > maxPopupHeight
    }

    private var listTextColor: Color {
        switch colorScheme {
        case .light:
            return Color(nsColor: .labelColor)
        case .dark:
            return Color.white.opacity(0.9)
        @unknown default:
            return Color(nsColor: .labelColor)
        }
    }

    private var badgeTextColor: Color {
        switch colorScheme {
        case .light:
            return Color(nsColor: .secondaryLabelColor)
        case .dark:
            return Color.white.opacity(0.72)
        @unknown default:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    private var badgeBackgroundColor: Color {
        switch colorScheme {
        case .light:
            return Color.black.opacity(0.06)
        case .dark:
            return Color.white.opacity(0.08)
        @unknown default:
            return Color.black.opacity(0.06)
        }
    }

    private var rowHighlightColor: Color {
        switch colorScheme {
        case .light:
            return Color.black.opacity(0.07)
        case .dark:
            return Color.white.opacity(0.12)
        @unknown default:
            return Color.black.opacity(0.07)
        }
    }

    private var popupOverlayGradientColors: [Color] {
        switch colorScheme {
        case .light:
            return [
                Color.white.opacity(0.55),
                Color.white.opacity(0.2),
            ]
        case .dark:
            return [
                Color.black.opacity(0.26),
                Color.black.opacity(0.14),
            ]
        @unknown default:
            return [
                Color.white.opacity(0.55),
                Color.white.opacity(0.2),
            ]
        }
    }

    private var popupBorderGradientColors: [Color] {
        switch colorScheme {
        case .light:
            return [
                Color.white.opacity(0.65),
                Color.black.opacity(0.12),
            ]
        case .dark:
            return [
                Color.white.opacity(0.22),
                Color.white.opacity(0.06),
            ]
        @unknown default:
            return [
                Color.white.opacity(0.65),
                Color.black.opacity(0.12),
            ]
        }
    }

    private var popupShadowColor: Color {
        switch colorScheme {
        case .light:
            return Color.black.opacity(0.18)
        case .dark:
            return Color.black.opacity(0.45)
        @unknown default:
            return Color.black.opacity(0.18)
        }
    }

    @ViewBuilder
    private var rowsView: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
            Button {
                #if DEBUG
                let suggestionKind: String = {
                    switch item.kind {
                    case .search:
                        return "search"
                    case .navigate:
                        return "navigate"
                    case .history:
                        return "history"
                    case .switchToTab:
                        return "switchToTab"
                    case .remote:
                        return "remote"
                    }
                }()
                cmuxDebugLog("browser.suggestionClick index=\(idx) kind=\(suggestionKind) textBytes=\(item.listText.utf8.count)")
                #endif
                onCommit(item)
            } label: {
                HStack(spacing: 6) {
                        Text(item.listText)
                            .font(.system(size: 11))
                            .foregroundStyle(listTextColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let badge = item.trailingBadgeText {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(badgeTextColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(badgeBackgroundColor)
                                )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: rowHeight(for: item),
                        maxHeight: rowHeight(for: item),
                        alignment: .leading
                    )
                    .background(
                        RoundedRectangle(cornerRadius: rowHighlightCornerRadius, style: .continuous)
                            .fill(
                                idx == selectedIndex
                                    ? rowHighlightColor
                                    : Color.clear
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("BrowserOmnibarSuggestions.Row.\(idx)")
                .accessibilityValue(
                    idx == selectedIndex
                        ? "selected \(item.listText)"
                        : item.listText
                )
                .onHover { hovering in
                    if hovering, idx != selectedIndex, isPointerDrivenSelectionEvent {
                        onHighlight(idx)
                    }
                }
                .animation(.none, value: selectedIndex)
            }

        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var body: some View {
        Group {
            if shouldScroll {
                ScrollView {
                    rowsView
                }
            } else {
                rowsView
            }
        }
        .frame(height: popupHeight, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if searchSuggestionsEnabled, isLoadingRemoteSuggestions {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 7)
                    .padding(.trailing, 14)
                    .opacity(0.75)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: popupOverlayGradientColors,
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: popupBorderGradientColors,
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous))
        .shadow(color: popupShadowColor, radius: 20, y: 10)
        .contentShape(RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityRespondsToUserInteraction(true)
        .accessibilityIdentifier("BrowserOmnibarSuggestions")
        .accessibilityLabel(String(localized: "browser.addressBarSuggestions", defaultValue: "Address bar suggestions"))
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
        private final class HostedInspectorSideDockContainerView: NSView {
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
        private(set) var geometryRevision: UInt64 = 0
        private var lastReportedGeometryState: GeometryState?
        private var hasPendingGeometryNotification = false
        private weak var hostedWebView: WKWebView?
        private var hostedWebViewConstraints: [NSLayoutConstraint] = []
        private weak var localInlineSlotView: WindowBrowserSlotView?
        private var localInlineSlotConstraints: [NSLayoutConstraint] = []
        private weak var hostedInspectorSideDockContainerView: HostedInspectorSideDockContainerView?
        private var hostedInspectorSideDockConstraints: [NSLayoutConstraint] = []
        private weak var hostedInspectorFrontendWebView: WKWebView?
        private struct HostedInspectorDividerHit {
            let containerView: NSView
            let pageView: NSView
            let inspectorView: NSView
            let dockSide: HostedInspectorDockSide
        }

        private struct GeometryState: Equatable {
            let frame: CGRect
            let bounds: CGRect
            let windowNumber: Int?
            let superviewID: ObjectIdentifier?
        }

        private struct HostedInspectorDividerDragState {
            let containerView: NSView
            let pageView: NSView
            let inspectorView: NSView
            let dockSide: HostedInspectorDockSide
            let initialWindowX: CGFloat
            let initialPageFrame: NSRect
            let initialInspectorFrame: NSRect
        }

        private enum DividerCursorKind: Equatable {
            case vertical

            var cursor: NSCursor { .resizeLeftRight }
        }

        private static let hostedInspectorDividerHitExpansion: CGFloat = 10
        private static let minimumHostedInspectorWidth: CGFloat = 120
        private static let minimumHostedInspectorPageWidthForSideDock: CGFloat = 240
        private static let adaptiveBottomDockRequestCooldown: TimeInterval = 0.25
        private var trackingArea: NSTrackingArea?
        private var activeDividerCursorKind: DividerCursorKind?
        private var hostedInspectorDividerDrag: HostedInspectorDividerDragState?
        private var preferredHostedInspectorWidth: CGFloat?
        private var preferredHostedInspectorWidthFraction: CGFloat?
        var onPreferredHostedInspectorWidthChanged: ((CGFloat, CGFloat?) -> Void)?
        private weak var hostedInspectorSideDockPageView: NSView?
        private weak var hostedInspectorSideDockInspectorView: NSView?
        private var hostedInspectorSideDockDockSide: HostedInspectorDockSide?
        private var isHostedInspectorDividerDragActive = false
        private var isApplyingHostedInspectorLayout = false
        private var hostedInspectorReapplyWorkItem: DispatchWorkItem?
        private var hostedInspectorDockConfigurationSyncWorkItem: DispatchWorkItem?
        private var hostedInspectorSideDockPromotionTask: Task<Void, Never>?
        private var hostedInspectorSideDockPromotionTaskID: UUID?
        private var adaptiveBottomDockRequestCooldownDeadline: Date?
        private var recordedHostedInspectorSideDockWidth: CGFloat?
        private var lastHostedInspectorManualSideDockAllowed: Bool?
        private var lastHostedInspectorLayoutBoundsSize: NSSize?
#if DEBUG
        private var lastLoggedHostedInspectorFrames: (page: NSRect, inspector: NSRect)?
        private var hasLoggedMissingHostedInspectorCandidate = false
#endif

        deinit {
            hostedInspectorReapplyWorkItem?.cancel()
            hostedInspectorDockConfigurationSyncWorkItem?.cancel()
            hostedInspectorSideDockPromotionTask?.cancel()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            clearActiveDividerCursor(restoreArrow: false)
        }

        private func recordPreferredHostedInspectorWidth(_ width: CGFloat, containerBounds: NSRect) {
            preferredHostedInspectorWidth = width
            guard containerBounds.width > 0 else {
                preferredHostedInspectorWidthFraction = nil
                onPreferredHostedInspectorWidthChanged?(width, nil)
                return
            }
            preferredHostedInspectorWidthFraction = width / containerBounds.width
            onPreferredHostedInspectorWidthChanged?(width, preferredHostedInspectorWidthFraction)
        }

        private func resolvedPreferredHostedInspectorWidth(in containerBounds: NSRect) -> CGFloat? {
            if let preferredHostedInspectorWidthFraction, containerBounds.width > 0 {
                return max(0, containerBounds.width * preferredHostedInspectorWidthFraction)
            }
            return preferredHostedInspectorWidth
        }

        func setPreferredHostedInspectorWidth(width: CGFloat?, widthFraction: CGFloat?) {
            preferredHostedInspectorWidth = width
            preferredHostedInspectorWidthFraction = widthFraction
        }

        private func recordHostedInspectorSideDockWidth(_ width: CGFloat) {
            guard width > 1 else { return }
            recordedHostedInspectorSideDockWidth = max(Self.minimumHostedInspectorWidth, width)
        }

        private func shouldAllowHostedInspectorManualSideDock() -> Bool {
            let containerWidth = max(0, bounds.width)
            guard containerWidth > 1 else { return true }
            let baselineWidth = max(
                Self.minimumHostedInspectorWidth,
                recordedHostedInspectorSideDockWidth ?? Self.minimumHostedInspectorWidth
            )
            return containerWidth - baselineWidth >= Self.minimumHostedInspectorPageWidthForSideDock
        }

        private func updateHostedInspectorDockControlAvailabilityIfNeeded(reason: String) {
            guard let hostedInspectorFrontendWebView else {
                lastHostedInspectorManualSideDockAllowed = nil
                return
            }

            let sideDockAllowed = shouldAllowHostedInspectorManualSideDock()
            guard lastHostedInspectorManualSideDockAllowed != sideDockAllowed else { return }
            lastHostedInspectorManualSideDockAllowed = sideDockAllowed

            let sideDockAllowedLiteral = sideDockAllowed ? "true" : "false"
#if DEBUG
            let recordedWidthDesc = recordedHostedInspectorSideDockWidth.map {
                String(format: "%.1f", $0)
            } ?? "nil"
            cmuxDebugLog(
                "browser.panel.hostedInspector stage=\(reason).dockControls " +
                "host=\(Self.debugObjectID(self)) allowSideDock=\(sideDockAllowed ? 1 : 0) " +
                "recordedWidth=\(recordedWidthDesc) bounds=\(Self.debugRect(bounds))"
            )
#endif
            hostedInspectorFrontendWebView.evaluateJavaScript(
                """
                (() => {
                    if (typeof WI === "undefined")
                        return null;
                    const allowSideDock = \(sideDockAllowedLiteral);
                    if (!WI.__cmuxOriginalUpdateDockNavigationItems && typeof WI._updateDockNavigationItems === "function")
                        WI.__cmuxOriginalUpdateDockNavigationItems = WI._updateDockNavigationItems;
                    if (!WI.__cmuxOriginalDockLeft && typeof WI._dockLeft === "function")
                        WI.__cmuxOriginalDockLeft = WI._dockLeft;
                    if (!WI.__cmuxOriginalDockRight && typeof WI._dockRight === "function")
                        WI.__cmuxOriginalDockRight = WI._dockRight;
                    if (!WI.__cmuxOriginalTogglePreviousDockConfiguration && typeof WI._togglePreviousDockConfiguration === "function")
                        WI.__cmuxOriginalTogglePreviousDockConfiguration = WI._togglePreviousDockConfiguration;
                    function callOriginal(fn, event) {
                        return typeof fn === "function" ? fn.call(WI, event) : null;
                    }
                    function updateButton(button, hidden) {
                        if (!button)
                            return;
                        button.hidden = hidden;
                        if (button.element) {
                            button.element.style.display = hidden ? "none" : "";
                            button.element.style.pointerEvents = hidden ? "none" : "";
                        }
                    }
                    function enforceDockControls() {
                        const disallowSideDock = !WI.__cmuxAllowSideDock;
                        updateButton(WI._dockLeftTabBarButton, disallowSideDock || WI.dockConfiguration === WI.DockConfiguration.Left);
                        updateButton(WI._dockRightTabBarButton, disallowSideDock || WI.dockConfiguration === WI.DockConfiguration.Right);
                    }
                    WI.__cmuxAllowSideDock = allowSideDock;
                    WI._dockLeft = function(event) {
                        if (!WI.__cmuxAllowSideDock)
                            return callOriginal(WI._dockBottom, event);
                        return callOriginal(WI.__cmuxOriginalDockLeft, event);
                    };
                    WI._dockRight = function(event) {
                        if (!WI.__cmuxAllowSideDock)
                            return callOriginal(WI._dockBottom, event);
                        return callOriginal(WI.__cmuxOriginalDockRight, event);
                    };
                    WI._togglePreviousDockConfiguration = function(event) {
                        const previousSideDock = WI._previousDockConfiguration === WI.DockConfiguration.Left || WI._previousDockConfiguration === WI.DockConfiguration.Right;
                        if (!WI.__cmuxAllowSideDock && previousSideDock)
                            return callOriginal(WI._dockBottom, event);
                        return callOriginal(WI.__cmuxOriginalTogglePreviousDockConfiguration, event);
                    };
                    WI._updateDockNavigationItems = function(...args) {
                        if (typeof WI.__cmuxOriginalUpdateDockNavigationItems === "function")
                            WI.__cmuxOriginalUpdateDockNavigationItems.apply(WI, args);
                        enforceDockControls();
                    };
                    WI._updateDockNavigationItems();
                    return WI.__cmuxAllowSideDock;
                })();
                """,
                completionHandler: nil
            )
        }

        func containsManagedLocalInlineContent(_ view: NSView) -> Bool {
            if let localInlineSlotView,
               view === localInlineSlotView || view.isDescendant(of: localInlineSlotView) {
                return true
            }
            if let hostedInspectorSideDockContainerView,
               view === hostedInspectorSideDockContainerView || view.isDescendant(of: hostedInspectorSideDockContainerView) {
                return true
            }
            return false
        }

        func currentHostedWebViewContainer(preferredSlotView: WindowBrowserSlotView) -> NSView {
            if let hostedInspectorSideDockContainerView,
               let hostedInspectorSideDockPageView,
               hostedWebView?.isDescendant(of: hostedInspectorSideDockContainerView) == true,
               hostedInspectorSideDockPageView.isDescendant(of: hostedInspectorSideDockContainerView) {
                return hostedInspectorSideDockContainerView
            }
            return preferredSlotView
        }

        func setHostedInspectorFrontendWebView(_ webView: WKWebView?) {
            hostedInspectorFrontendWebView = webView
            lastHostedInspectorManualSideDockAllowed = nil
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "setHostedInspectorFrontendWebView")
        }

        private var hasStoredHostedInspectorWidthPreference: Bool {
            preferredHostedInspectorWidth != nil || preferredHostedInspectorWidthFraction != nil
        }

#if DEBUG
        private static func shouldLogPointerEvent(_ event: NSEvent?) -> Bool {
            switch event?.type {
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
                return true
            default:
                return false
            }
        }

        private func debugLogHitTest(stage: String, point: NSPoint, passThrough: Bool, hitView: NSView?) {
            let event = NSApp.currentEvent
            guard Self.shouldLogPointerEvent(event) else { return }

            let hitDesc: String = {
                guard let hitView else { return "nil" }
                let token = Unmanaged.passUnretained(hitView).toOpaque()
                return "\(type(of: hitView))@\(token)"
            }()
            let hostRectInContent: NSRect = {
                guard let window, let contentView = window.contentView else { return .zero }
                return contentView.convert(bounds, from: self)
            }()
            cmuxDebugLog(
                "browser.panel.host stage=\(stage) event=\(String(describing: event?.type)) " +
                "point=\(String(format: "%.1f,%.1f", point.x, point.y)) pass=\(passThrough ? 1 : 0) " +
                "hostFrameInContent=\(String(format: "%.1f,%.1f %.1fx%.1f", hostRectInContent.origin.x, hostRectInContent.origin.y, hostRectInContent.width, hostRectInContent.height)) " +
                "hit=\(hitDesc)"
            )
        }

        private static func debugObjectID(_ object: AnyObject?) -> String {
            guard let object else { return "nil" }
            return String(describing: Unmanaged.passUnretained(object).toOpaque())
        }

        private static func debugRect(_ rect: NSRect) -> String {
            String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.width, rect.height)
        }

        private func debugLogHostedInspectorFrames(
            stage: String,
            point: NSPoint? = nil,
            hit: HostedInspectorDividerHit
        ) {
            let pointDesc = point.map { String(format: "%.1f,%.1f", $0.x, $0.y) } ?? "nil"
            let preferredWidthDesc = preferredHostedInspectorWidth.map { String(format: "%.1f", $0) } ?? "nil"
            cmuxDebugLog(
                "browser.panel.hostedInspector stage=\(stage) point=\(pointDesc) " +
                "host=\(Self.debugObjectID(self)) container=\(Self.debugObjectID(hit.containerView)) " +
                "page=\(Self.debugObjectID(hit.pageView)) inspector=\(Self.debugObjectID(hit.inspectorView)) " +
                "preferredWidth=\(preferredWidthDesc) " +
                "hostFrame=\(Self.debugRect(frame)) hostBounds=\(Self.debugRect(bounds)) " +
                "containerBounds=\(Self.debugRect(hit.containerView.bounds)) " +
                "pageFrame=\(Self.debugRect(hit.pageView.frame)) " +
                "inspectorFrame=\(Self.debugRect(hit.inspectorView.frame))"
            )
        }

        private func debugLogHostedInspectorLayoutIfNeeded(reason: String) {
            guard let hit = hostedInspectorDividerCandidate() else {
                if !hasLoggedMissingHostedInspectorCandidate,
                   lastLoggedHostedInspectorFrames != nil || preferredHostedInspectorWidth != nil {
                    let preferredWidthDesc = preferredHostedInspectorWidth.map {
                        String(format: "%.1f", $0)
                    } ?? "nil"
                    lastLoggedHostedInspectorFrames = nil
                    hasLoggedMissingHostedInspectorCandidate = true
                    cmuxDebugLog(
                        "browser.panel.hostedInspector stage=\(reason).candidateMissing " +
                        "host=\(Self.debugObjectID(self)) preferredWidth=\(preferredWidthDesc)"
                    )
                }
                return
            }
            hasLoggedMissingHostedInspectorCandidate = false

            let nextFrames = (page: hit.pageView.frame, inspector: hit.inspectorView.frame)
            if let lastLoggedHostedInspectorFrames,
               Self.rectApproximatelyEqual(lastLoggedHostedInspectorFrames.page, nextFrames.page),
               Self.rectApproximatelyEqual(lastLoggedHostedInspectorFrames.inspector, nextFrames.inspector) {
                return
            }

            lastLoggedHostedInspectorFrames = nextFrames
            debugLogHostedInspectorFrames(stage: "\(reason).layout", hit: hit)
        }
#endif

        private static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.5) -> Bool {
            abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
                abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
                abs(lhs.width - rhs.width) <= epsilon &&
                abs(lhs.height - rhs.height) <= epsilon
        }

        private static func sizeApproximatelyEqual(_ lhs: NSSize, _ rhs: NSSize, epsilon: CGFloat = 0.5) -> Bool {
            abs(lhs.width - rhs.width) <= epsilon &&
                abs(lhs.height - rhs.height) <= epsilon
        }

        private func currentGeometryState() -> GeometryState {
            GeometryState(
                frame: frame,
                bounds: bounds,
                windowNumber: window?.windowNumber,
                superviewID: superview.map(ObjectIdentifier.init)
            )
        }

        /// Record that geometry changed without firing the callback immediately.
        /// `setFrameOrigin`/`setFrameSize` can fire multiple times before `layout()`;
        /// deferring avoids redundant portal-sync cascades during divider drag.
        /// A dispatch fallback ensures the callback fires even if `layout()` is not called.
        /// Note: `lastReportedGeometryState` and `geometryRevision` are only updated
        /// when the callback actually fires, so `updateNSView` sees a revision that
        /// is strictly tied to emitted callbacks (no premature increments).
        private func markGeometryDirtyIfNeeded() {
            let state = currentGeometryState()
            guard state != lastReportedGeometryState else { return }
            guard !hasPendingGeometryNotification else { return }
            hasPendingGeometryNotification = true
            DispatchQueue.main.async { [weak self] in
                self?.notifyGeometryChangedIfNeeded()
            }
        }

        /// Check for geometry changes and fire the callback. Also flushes any pending
        /// dirty state from `markGeometryDirtyIfNeeded` so `layout()` supersedes the
        /// async fallback.  Only updates `lastReportedGeometryState` / `geometryRevision`
        /// when the callback is emitted, keeping the revision in sync with actual
        /// notifications.
        private func notifyGeometryChangedIfNeeded() {
            hasPendingGeometryNotification = false
            let state = currentGeometryState()
            guard state != lastReportedGeometryState else { return }
            lastReportedGeometryState = state
            geometryRevision &+= 1
            onGeometryChanged?()
        }

        func ensureLocalInlineSlotView() -> WindowBrowserSlotView {
            if let localInlineSlotView, localInlineSlotView.superview === self {
                localInlineSlotView.isHidden = false
                return localInlineSlotView
            }

            let slotView = WindowBrowserSlotView(frame: bounds)
            slotView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(slotView, positioned: .above, relativeTo: nil)
            localInlineSlotConstraints = [
                slotView.topAnchor.constraint(equalTo: topAnchor),
                slotView.bottomAnchor.constraint(equalTo: bottomAnchor),
                slotView.leadingAnchor.constraint(equalTo: leadingAnchor),
                slotView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            NSLayoutConstraint.activate(localInlineSlotConstraints)
            localInlineSlotView = slotView
            return slotView
        }

#if DEBUG
        func localInlineSlotViewForDebug() -> WindowBrowserSlotView? {
            localInlineSlotView
        }
#endif

        func setLocalInlineSlotHidden(_ hidden: Bool) {
            localInlineSlotView?.isHidden = hidden
            if hidden {
                notifyHostedWebKitHidden(reason: "slotHidden")
            }
        }

        func clearLocalInlineCallbacks() {
            onPreferredHostedInspectorWidthChanged = nil
            localInlineSlotView?.onHostedInspectorLayout = nil
        }

        private func appendHostedWebKitSubviews(
            in root: NSView,
            to result: inout [WKWebView],
            seen: inout Set<ObjectIdentifier>
        ) {
            if let webView = root as? WKWebView {
                guard !webView.cmuxBrowserPanelIsInspectorFrontend else { return }
                let id = ObjectIdentifier(webView)
                if seen.insert(id).inserted {
                    result.append(webView)
                }
            }
            for subview in root.subviews {
                appendHostedWebKitSubviews(in: subview, to: &result, seen: &seen)
            }
        }

        private var hostedWebKitSubviews: [WKWebView] {
            var result: [WKWebView] = []
            var seen = Set<ObjectIdentifier>()

            func append(_ webView: WKWebView?) {
                guard let webView else { return }
                guard !webView.cmuxBrowserPanelIsInspectorFrontend else { return }
                let id = ObjectIdentifier(webView)
                guard seen.insert(id).inserted else { return }
                result.append(webView)
            }

            append(hostedWebView)
            appendHostedWebKitSubviews(in: self, to: &result, seen: &seen)
            return result
        }

        private func notifyHostedWebKitHidden(reason: String) {
            for webView in hostedWebKitSubviews {
                webView.cmuxBrowserPanelNotifyHidden(reason: reason)
            }
        }

        func refreshHostedWebKitPresentation(
            reason: String,
            forceLifecycleRefresh: Bool = false
        ) {
            guard let localInlineSlotView else { return }
            guard !localInlineSlotView.isHidden else { return }
            let hostedWebKitSubviews = hostedWebKitSubviews
            guard !hostedWebKitSubviews.isEmpty else { return }

            localInlineSlotView.needsLayout = true
            localInlineSlotView.needsDisplay = true
            localInlineSlotView.setNeedsDisplay(localInlineSlotView.bounds)

            needsLayout = true
            needsDisplay = true
            setNeedsDisplay(bounds)

            for webView in hostedWebKitSubviews {
                if let scrollView = webView.enclosingScrollView {
                    scrollView.needsLayout = true
                    scrollView.needsDisplay = true
                    scrollView.setNeedsDisplay(scrollView.bounds)
                    scrollView.contentView.needsLayout = true
                    scrollView.contentView.needsDisplay = true
                }
                webView.needsLayout = true
                webView.needsDisplay = true
                webView.setNeedsDisplay(webView.bounds)
            }

            localInlineSlotView.layoutSubtreeIfNeeded()
            layoutSubtreeIfNeeded()

            for webView in hostedWebKitSubviews {
                if let scrollView = webView.enclosingScrollView {
                    scrollView.layoutSubtreeIfNeeded()
                    scrollView.contentView.layoutSubtreeIfNeeded()
                    scrollView.displayIfNeeded()
                }
                webView.layoutSubtreeIfNeeded()
                if forceLifecycleRefresh {
                    webView.cmuxBrowserPanelForceRenderingStateRefresh(reason: reason)
                } else {
                    webView.cmuxBrowserPanelReattachRenderingState(reason: reason)
                }
                webView.displayIfNeeded()
            }

            localInlineSlotView.displayIfNeeded()
            displayIfNeeded()
            window?.displayIfNeeded()
        }

        func prepareForWindowPortalHosting() {
            hostedInspectorDockConfigurationSyncWorkItem?.cancel()
            hostedInspectorDockConfigurationSyncWorkItem = nil
            notifyHostedWebKitHidden(reason: "prepareForWindowPortalHosting")
            deactivateHostedInspectorSideDockIfNeeded(reparentTo: localInlineSlotView)
            hostedInspectorFrontendWebView = nil
        }

        func clearStaleHostedInspectorOwnershipState() {
            hostedInspectorDockConfigurationSyncWorkItem?.cancel()
            hostedInspectorDockConfigurationSyncWorkItem = nil
            hostedInspectorFrontendWebView = nil
            lastHostedInspectorManualSideDockAllowed = nil
        }

        func releaseHostedWebViewConstraints() {
            NSLayoutConstraint.deactivate(hostedWebViewConstraints)
            hostedWebViewConstraints = []
            hostedWebView = nil
        }

        func pinHostedWebView(_ webView: WKWebView, in container: NSView) {
            guard webView.superview === container || webView.isDescendant(of: container) else { return }

            let hasCompanionWKSubviews = Self.hasWebKitCompanionSubview(
                in: container,
                primaryWebView: webView
            )
            let needsPlainWebViewFrameReset =
                webView.superview === container &&
                !hasCompanionWKSubviews &&
                Self.frameDiffersFromBounds(webView.frame, bounds: container.bounds)
            let needsFrameHosting =
                hostedWebView !== webView ||
                !hostedWebViewConstraints.isEmpty ||
                needsPlainWebViewFrameReset ||
                !webView.translatesAutoresizingMaskIntoConstraints ||
                webView.autoresizingMask != [.width, .height]
            guard needsFrameHosting else {
                needsLayout = true
                layoutSubtreeIfNeeded()
                return
            }

            NSLayoutConstraint.deactivate(hostedWebViewConstraints)
            hostedWebViewConstraints = []
            hostedWebView = webView

            // WebKit's attached inspector does not reliably dock into a constraint-managed
            // WKWebView hierarchy on macOS. Host the moved webview with autoresizing and
            // preserve WebKit-managed split frames when docked DevTools siblings exist.
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.width, .height]
            if webView.superview === container && !hasCompanionWKSubviews {
                webView.frame = container.bounds
            }
            needsLayout = true
            layoutSubtreeIfNeeded()
        }

        private static func frameDiffersFromBounds(_ frame: NSRect, bounds: NSRect, epsilon: CGFloat = 0.5) -> Bool {
            abs(frame.minX - bounds.minX) > epsilon ||
                abs(frame.minY - bounds.minY) > epsilon ||
                abs(frame.width - bounds.width) > epsilon ||
                abs(frame.height - bounds.height) > epsilon
        }

        private static func hasWebKitCompanionSubview(in host: NSView, primaryWebView: WKWebView) -> Bool {
            var stack = host.subviews.filter { $0 !== primaryWebView }
            while let current = stack.popLast() {
                if current.isDescendant(of: primaryWebView) {
                    continue
                }
                if current.isHidden || current.alphaValue <= 0 {
                    continue
                }
                if String(describing: type(of: current)).contains("WK") {
                    let width = max(current.frame.width, current.bounds.width)
                    let height = max(current.frame.height, current.bounds.height)
                    if width > 1, height > 1 {
                        return true
                    }
                    continue
                }
                stack.append(contentsOf: current.subviews)
            }
            return false
        }

        private func ensureHostedInspectorSideDockContainerView() -> HostedInspectorSideDockContainerView {
            if let hostedInspectorSideDockContainerView,
               hostedInspectorSideDockContainerView.superview === self {
                hostedInspectorSideDockContainerView.isHidden = false
                return hostedInspectorSideDockContainerView
            }

            let containerView = HostedInspectorSideDockContainerView(frame: bounds)
            containerView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(containerView, positioned: .above, relativeTo: localInlineSlotView)
            hostedInspectorSideDockConstraints = [
                containerView.topAnchor.constraint(equalTo: topAnchor),
                containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            NSLayoutConstraint.activate(hostedInspectorSideDockConstraints)
            hostedInspectorSideDockContainerView = containerView
            return containerView
        }

        private func moveHostedInspectorSubviewIfNeeded(_ view: NSView, to container: NSView) {
            guard view.superview !== container else { return }
            let frameInWindow = view.superview?.convert(view.frame, to: nil) ?? convert(view.frame, to: nil)
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: nil)
            view.frame = container.convert(frameInWindow, from: nil)
        }

        private func isHostedInspectorSideDockActive() -> Bool {
            guard let hostedInspectorSideDockContainerView,
                  let hostedInspectorSideDockPageView,
                  let hostedInspectorSideDockInspectorView else {
                return false
            }
            return hostedInspectorSideDockPageView.superview === hostedInspectorSideDockContainerView &&
                hostedInspectorSideDockInspectorView.superview === hostedInspectorSideDockContainerView
        }

        private func isHostedInspectorSideDockHit(_ hit: HostedInspectorDividerHit) -> Bool {
            guard let hostedInspectorSideDockContainerView else { return false }
            return hit.containerView === hostedInspectorSideDockContainerView
        }

        private func activateHostedInspectorSideDockIfNeeded(using hit: HostedInspectorDividerHit) {
            let containerView = ensureHostedInspectorSideDockContainerView()
            moveHostedInspectorSubviewIfNeeded(hit.pageView, to: containerView)
            moveHostedInspectorSubviewIfNeeded(hit.inspectorView, to: containerView)
            hostedInspectorSideDockPageView = hit.pageView
            hostedInspectorSideDockInspectorView = hit.inspectorView
            hostedInspectorSideDockDockSide = hit.dockSide
            layoutHostedInspectorSideDockIfNeeded(reason: "sideDock.activate")
        }

        @discardableResult
        func promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded() -> Bool {
            guard !isHostedInspectorSideDockActive(),
                  let slotView = localInlineSlotView,
                  let hit = hostedInspectorDividerCandidateUsingKnownWebViews(in: slotView) else {
                return false
            }

            // The inspector frontend sometimes reports its dock configuration a tick
            // late after local-inline reattach. Promote the visible left/right split
            // immediately so drag routing stays symmetric on both dock sides.
            if shouldForceHostedInspectorBottomDock(using: hit) {
                _ = requestAdaptiveHostedInspectorBottomDock(reason: "sideDock.promote")
                return false
            }
            activateHostedInspectorSideDockIfNeeded(using: hit)
            return isHostedInspectorSideDockActive()
        }

        /// Schedules `promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded`
        /// for the next runloop tick when a promotion is actually pending, so the
        /// hierarchy mutation it performs never runs inside the `layout()` pass
        /// that observed the candidate (see the note in `layout()`). The candidate
        /// lookup here is read-only; the deferred work re-validates all state
        /// before mutating, so it is safe even if the layout changes in between.
        private func scheduleHostedInspectorSideDockPromotionIfNeeded() {
            guard hostedInspectorSideDockPromotionTask == nil else { return }
            guard !isHostedInspectorSideDockActive(),
                  let slotView = localInlineSlotView,
                  hostedInspectorDividerCandidateUsingKnownWebViews(in: slotView) != nil else {
                return
            }
            let taskID = UUID()
            hostedInspectorSideDockPromotionTaskID = taskID
            let task = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                guard self.hostedInspectorSideDockPromotionTaskID == taskID else { return }
                self.hostedInspectorSideDockPromotionTask = nil
                self.hostedInspectorSideDockPromotionTaskID = nil
                guard !Task.isCancelled else { return }
                _ = self.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded()
            }
            hostedInspectorSideDockPromotionTask = task
        }

        private func deactivateHostedInspectorSideDockIfNeeded(reparentTo slotView: WindowBrowserSlotView?) {
            guard let slotView,
                  let pageView = hostedInspectorSideDockPageView,
                  let inspectorView = hostedInspectorSideDockInspectorView else {
                hostedInspectorSideDockPageView = nil
                hostedInspectorSideDockInspectorView = nil
                hostedInspectorSideDockDockSide = nil
                hostedInspectorSideDockContainerView?.isHidden = true
                return
            }

            moveHostedInspectorSubviewIfNeeded(pageView, to: slotView)
            moveHostedInspectorSubviewIfNeeded(inspectorView, to: slotView)
            hostedInspectorSideDockPageView = nil
            hostedInspectorSideDockInspectorView = nil
            hostedInspectorSideDockDockSide = nil
            hostedInspectorSideDockContainerView?.isHidden = true
        }

        private func layoutHostedInspectorSideDockIfNeeded(reason: String) {
            guard let containerView = hostedInspectorSideDockContainerView,
                  let pageView = hostedInspectorSideDockPageView,
                  let inspectorView = hostedInspectorSideDockInspectorView,
                  let dockSide = hostedInspectorSideDockDockSide else {
                return
            }
            let preferredWidth = resolvedPreferredHostedInspectorWidth(in: containerView.bounds) ?? max(0, inspectorView.frame.width)
            _ = applyHostedInspectorDividerWidth(
                preferredWidth,
                to: HostedInspectorDividerHit(
                    containerView: containerView,
                    pageView: pageView,
                    inspectorView: inspectorView,
                    dockSide: dockSide
                ),
                minimumInspectorWidth: Self.minimumHostedInspectorWidth,
                reason: reason
            )
        }

        func normalizeHostedInspectorLayoutIfNeeded(reason: String) {
            if enforceAdaptiveBottomDockIfNeeded(reason: "\(reason).adaptive") {
                return
            }
            _ = promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded()
            if isHostedInspectorSideDockActive() {
                layoutHostedInspectorSideDockIfNeeded(reason: reason)
            } else if !hasStoredHostedInspectorWidthPreference {
                captureHostedInspectorPreferredWidthFromCurrentLayout(reason: reason)
            }
        }

        private func shouldForceHostedInspectorBottomDock(using hit: HostedInspectorDividerHit) -> Bool {
            let containerWidth = max(0, hit.containerView.bounds.width)
            guard containerWidth > 1 else { return false }

            let currentInspectorWidth = max(0, hit.inspectorView.frame.width)
            let currentPageWidth = max(0, hit.pageView.frame.width)
            let remainingPageWidth = max(0, containerWidth - max(Self.minimumHostedInspectorWidth, currentInspectorWidth))
            let effectivePageWidth = min(currentPageWidth, remainingPageWidth)

            return effectivePageWidth < Self.minimumHostedInspectorPageWidthForSideDock
        }

        @discardableResult
        private func requestAdaptiveHostedInspectorBottomDock(reason: String) -> Bool {
            let now = Date()
            if let adaptiveBottomDockRequestCooldownDeadline, adaptiveBottomDockRequestCooldownDeadline > now {
                return true
            }
            guard let hostedInspectorFrontendWebView else { return false }

            adaptiveBottomDockRequestCooldownDeadline = now.addingTimeInterval(Self.adaptiveBottomDockRequestCooldown)
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: reason)
#if DEBUG
            cmuxDebugLog(
                "browser.panel.hostedInspector stage=\(reason).adaptiveBottomDock " +
                "host=\(Self.debugObjectID(self)) bounds=\(Self.debugRect(bounds))"
            )
#endif
            hostedInspectorFrontendWebView.evaluateJavaScript(
                "typeof WI !== 'undefined' ? WI._dockBottom() : null"
            ) { [weak self] _, _ in
                self?.scheduleHostedInspectorDockConfigurationSync(
                    reason: "\(reason).adaptiveBottomDock"
                )
            }
            return true
        }

        @discardableResult
        private func enforceAdaptiveBottomDockIfNeeded(reason: String) -> Bool {
            guard let hit = hostedInspectorDividerCandidate(),
                  shouldForceHostedInspectorBottomDock(using: hit) else {
                return false
            }
            recordHostedInspectorSideDockWidth(hit.inspectorView.frame.width)
            return requestAdaptiveHostedInspectorBottomDock(reason: reason)
        }

        fileprivate func scheduleHostedInspectorDockConfigurationSync(reason: String) {
            hostedInspectorDockConfigurationSyncWorkItem?.cancel()
            guard hostedInspectorFrontendWebView != nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                self?.syncHostedInspectorDockConfiguration(reason: reason)
            }
            hostedInspectorDockConfigurationSyncWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func syncHostedInspectorDockConfiguration(reason: String) {
            hostedInspectorDockConfigurationSyncWorkItem = nil
            guard let hostedInspectorFrontendWebView else { return }
            hostedInspectorFrontendWebView.evaluateJavaScript(
                "typeof WI === 'undefined' ? null : WI.dockConfiguration"
            ) { [weak self] result, _ in
                self?.applyHostedInspectorDockConfiguration(result as? String, reason: reason)
            }
        }

        private func applyHostedInspectorDockConfiguration(_ dockConfiguration: String?, reason: String) {
            switch dockConfiguration {
            case "left":
                hostedInspectorSideDockDockSide = .leading
                if isHostedInspectorSideDockActive() {
                    if enforceAdaptiveBottomDockIfNeeded(reason: "\(reason).dockLeft") {
                        return
                    }
                    layoutHostedInspectorSideDockIfNeeded(reason: "\(reason).dockLeft")
                } else if let slotView = localInlineSlotView,
                          let hit = hostedInspectorDividerCandidate(in: slotView),
                          hit.dockSide == .leading {
                    if shouldForceHostedInspectorBottomDock(using: hit) {
                        _ = requestAdaptiveHostedInspectorBottomDock(reason: "\(reason).dockLeft")
                        return
                    }
                    activateHostedInspectorSideDockIfNeeded(using: hit)
                }
            case "right":
                hostedInspectorSideDockDockSide = .trailing
                if isHostedInspectorSideDockActive() {
                    if enforceAdaptiveBottomDockIfNeeded(reason: "\(reason).dockRight") {
                        return
                    }
                    layoutHostedInspectorSideDockIfNeeded(reason: "\(reason).dockRight")
                } else if let slotView = localInlineSlotView,
                          let hit = hostedInspectorDividerCandidate(in: slotView),
                          hit.dockSide == .trailing {
                    if shouldForceHostedInspectorBottomDock(using: hit) {
                        _ = requestAdaptiveHostedInspectorBottomDock(reason: "\(reason).dockRight")
                        return
                    }
                    activateHostedInspectorSideDockIfNeeded(using: hit)
                }
            default:
                adaptiveBottomDockRequestCooldownDeadline = nil
                if isHostedInspectorSideDockActive() {
                    deactivateHostedInspectorSideDockIfNeeded(reparentTo: localInlineSlotView)
                    if dockConfiguration == "bottom" {
                        hostedInspectorFrontendWebView?.evaluateJavaScript(
                            "typeof WI !== 'undefined' ? WI._dockBottom() : null",
                            completionHandler: nil
                        )
                    }
                }
            }
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "\(reason).dockConfiguration")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                notifyHostedWebKitHidden(reason: "viewDidMoveToWindow")
                clearActiveDividerCursor(restoreArrow: false)
            } else {
                scheduleHostedInspectorDividerReapply(reason: "viewDidMoveToWindow")
                scheduleHostedInspectorDockConfigurationSync(reason: "viewDidMoveToWindow")
                refreshHostedWebKitPresentation(
                    reason: "viewDidMoveToWindow",
                    forceLifecycleRefresh: hostedInspectorFrontendWebView != nil
                )
            }
            window?.invalidateCursorRects(for: self)
            onDidMoveToWindow?()
            notifyGeometryChangedIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "viewDidMoveToWindow")
#endif
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleHostedInspectorDividerReapply(reason: "viewDidMoveToSuperview")
            scheduleHostedInspectorDockConfigurationSync(reason: "viewDidMoveToSuperview")
            notifyGeometryChangedIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "viewDidMoveToSuperview")
#endif
        }

        override func layout() {
            super.layout()
            if enforceAdaptiveBottomDockIfNeeded(reason: "host.layout") {
                updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "host.layout")
                notifyGeometryChangedIfNeeded()
#if DEBUG
                debugLogHostedInspectorLayoutIfNeeded(reason: "layout")
#endif
                return
            }
            // Defer this hierarchy mutation out of `layout()` to avoid #6150.
            scheduleHostedInspectorSideDockPromotionIfNeeded()
            if let previousSize = lastHostedInspectorLayoutBoundsSize,
               Self.sizeApproximatelyEqual(previousSize, bounds.size, epsilon: 0.5) {
                // Origin-only frame churn is common while the surrounding split layout
                // settles. Reapplying the side-docked inspector at the same size fights
                // WebKit's own dock layout and shows up as visible flicker.
                if !isHostedInspectorDividerDragActive {
                    if hasStoredHostedInspectorWidthPreference {
                        reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: "host.layout.sameSize")
                    } else if !isHostedInspectorSideDockActive() {
                        captureHostedInspectorPreferredWidthFromCurrentLayout(reason: "host.layout.sameSize")
                    }
                }
                updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "host.layout.sameSize")
                notifyGeometryChangedIfNeeded()
#if DEBUG
                debugLogHostedInspectorLayoutIfNeeded(reason: "layout")
#endif
                return
            }
            lastHostedInspectorLayoutBoundsSize = bounds.size
            if isHostedInspectorSideDockActive() {
                layoutHostedInspectorSideDockIfNeeded(reason: "host.layout.sideDock")
            } else if hasStoredHostedInspectorWidthPreference {
                reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: "host.layout")
            } else {
                captureHostedInspectorPreferredWidthFromCurrentLayout(reason: "host.layout")
            }
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "host.layout")
            scheduleHostedInspectorDockConfigurationSync(reason: "layout")
            notifyGeometryChangedIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "layout")
#endif
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            window?.invalidateCursorRects(for: self)
            // Mark dirty; the callback fires from layout() with the settled geometry.
            markGeometryDirtyIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "setFrameOrigin")
#endif
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
            // Mark dirty; the callback fires from layout() with the settled geometry.
            markGeometryDirtyIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "setFrameSize")
#endif
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard let hostedInspectorHit = hostedInspectorDividerCandidate() else { return }
            let clipped = hostedInspectorDividerHitRect(for: hostedInspectorHit).intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
            addCursorRect(clipped, cursor: NSCursor.resizeLeftRight)
        }

        override func updateTrackingAreas() {
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let options: NSTrackingArea.Options = [
                .inVisibleRect,
                .activeAlways,
                .cursorUpdate,
                .mouseMoved,
                .mouseEnteredAndExited,
                .enabledDuringMouseDrag,
            ]
            let next = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            addTrackingArea(next)
            trackingArea = next
            super.updateTrackingAreas()
        }

        override func cursorUpdate(with event: NSEvent) {
            updateDividerCursor(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            updateDividerCursor(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            clearActiveDividerCursor(restoreArrow: true)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hostedInspectorHit = hostedInspectorDividerHit(at: point)
            updateDividerCursor(at: point, hostedInspectorHit: hostedInspectorHit)
            let passThrough = shouldPassThroughToSidebarResizer(at: point, hostedInspectorHit: hostedInspectorHit)
            if passThrough {
#if DEBUG
                debugLogHitTest(stage: "hitTest.pass", point: point, passThrough: true, hitView: nil)
#endif
                return nil
            }
            if let hostedInspectorHit {
                if let nativeHit = nativeHostedInspectorHit(at: point, hostedInspectorHit: hostedInspectorHit) {
#if DEBUG
                    debugLogHitTest(stage: "hitTest.hostedInspectorNative", point: point, passThrough: false, hitView: nativeHit)
#endif
                    if nativeHit !== hostedInspectorHit.inspectorView &&
                        !hostedInspectorHit.inspectorView.isDescendant(of: nativeHit) {
                        return nativeHit
                    }
                }
#if DEBUG
                debugLogHitTest(
                    stage: "hitTest.hostedInspectorManual",
                    point: point,
                    passThrough: false,
                    hitView: self
                )
#endif
                return self
            }
            let hit = super.hitTest(point)
#if DEBUG
            debugLogHitTest(stage: "hitTest.result", point: point, passThrough: false, hitView: hit)
#endif
            return hit
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let hostedInspectorHit = hostedInspectorDividerHit(at: point) else {
                super.mouseDown(with: event)
                return
            }

            hostedInspectorReapplyWorkItem?.cancel()
            isHostedInspectorDividerDragActive = true
            hostedInspectorDividerDrag = HostedInspectorDividerDragState(
                containerView: hostedInspectorHit.containerView,
                pageView: hostedInspectorHit.pageView,
                inspectorView: hostedInspectorHit.inspectorView,
                dockSide: hostedInspectorHit.dockSide,
                initialWindowX: event.locationInWindow.x,
                initialPageFrame: hostedInspectorHit.pageView.frame,
                initialInspectorFrame: hostedInspectorHit.inspectorView.frame
            )
#if DEBUG
            debugLogHostedInspectorFrames(stage: "drag.start", point: point, hit: hostedInspectorHit)
#endif
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragState = hostedInspectorDividerDrag else {
                super.mouseDragged(with: event)
                return
            }

            let containerBounds = dragState.containerView.bounds
            let minimumInspectorWidth = Self.minimumHostedInspectorWidth
            let initialDividerX = dragState.dockSide.dividerX(
                pageFrame: dragState.initialPageFrame,
                inspectorFrame: dragState.initialInspectorFrame
            )
            let proposedDividerX = initialDividerX + (event.locationInWindow.x - dragState.initialWindowX)
            let clampedDividerX = dragState.dockSide.clampedDividerX(
                proposedDividerX,
                containerBounds: containerBounds,
                pageFrame: dragState.initialPageFrame,
                minimumInspectorWidth: minimumInspectorWidth
            )
            let inspectorWidth = dragState.dockSide.inspectorWidth(
                forDividerX: clampedDividerX,
                in: containerBounds
            )
            recordPreferredHostedInspectorWidth(inspectorWidth, containerBounds: containerBounds)
            _ = applyHostedInspectorDividerWidth(
                inspectorWidth,
                to: HostedInspectorDividerHit(
                    containerView: dragState.containerView,
                    pageView: dragState.pageView,
                    inspectorView: dragState.inspectorView,
                    dockSide: dragState.dockSide
                ),
                minimumInspectorWidth: Self.minimumHostedInspectorWidth,
                reason: "drag"
            )
#if DEBUG
            debugLogHostedInspectorFrames(
                stage: "drag.update",
                point: convert(event.locationInWindow, from: nil),
                hit: HostedInspectorDividerHit(
                    containerView: dragState.containerView,
                    pageView: dragState.pageView,
                    inspectorView: dragState.inspectorView,
                    dockSide: dragState.dockSide
                )
            )
#endif
            updateDividerCursor(
                at: convert(event.locationInWindow, from: nil),
                hostedInspectorHit: HostedInspectorDividerHit(
                    containerView: dragState.containerView,
                    pageView: dragState.pageView,
                    inspectorView: dragState.inspectorView,
                    dockSide: dragState.dockSide
                )
            )
        }

        override func mouseUp(with event: NSEvent) {
            let finalDragState = hostedInspectorDividerDrag
            hostedInspectorDividerDrag = nil
            isHostedInspectorDividerDragActive = false
            updateDividerCursor(at: convert(event.locationInWindow, from: nil))
            if let finalDragState {
#if DEBUG
                debugLogHostedInspectorFrames(
                    stage: "drag.end",
                    point: convert(event.locationInWindow, from: nil),
                    hit: HostedInspectorDividerHit(
                        containerView: finalDragState.containerView,
                        pageView: finalDragState.pageView,
                        inspectorView: finalDragState.inspectorView,
                        dockSide: finalDragState.dockSide
                    )
                )
#endif
                reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: "drag.end")
            }
            super.mouseUp(with: event)
        }

        private func shouldPassThroughToSidebarResizer(
            at point: NSPoint,
            hostedInspectorHit: HostedInspectorDividerHit? = nil
        ) -> Bool {
            if hostedInspectorHit != nil {
                return false
            }
            // Pass through narrow content-edge bands so shared sidebar divider
            // handles receive hover/click even when WKWebView is attached here.
            let isLeadingContentEdge = point.x >= 0 &&
                point.x <= SidebarResizeInteraction.contentSideHitWidth
            let isTrailingContentEdge = point.x >= bounds.maxX - SidebarResizeInteraction.contentSideHitWidth &&
                point.x <= bounds.maxX
            guard isLeadingContentEdge || isTrailingContentEdge else {
                return false
            }
            guard let window, let contentView = window.contentView else {
                return false
            }
            let hostRectInContent = contentView.convert(bounds, from: self)
            if isLeadingContentEdge {
                return hostRectInContent.minX > 1
            }
            return contentView.bounds.maxX - hostRectInContent.maxX > 24
        }

        private func updateDividerCursor(
            at point: NSPoint,
            hostedInspectorHit: HostedInspectorDividerHit? = nil
        ) {
            let resolvedHostedInspectorHit = hostedInspectorHit ?? hostedInspectorDividerHit(at: point)
            if shouldPassThroughToSidebarResizer(at: point, hostedInspectorHit: resolvedHostedInspectorHit) {
                clearActiveDividerCursor(restoreArrow: false)
                return
            }
            guard resolvedHostedInspectorHit != nil else {
                clearActiveDividerCursor(restoreArrow: true)
                return
            }
            activeDividerCursorKind = .vertical
            NSCursor.resizeLeftRight.set()
        }

        private func clearActiveDividerCursor(restoreArrow: Bool) {
            guard activeDividerCursorKind != nil else { return }
            window?.invalidateCursorRects(for: self)
            activeDividerCursorKind = nil
            if restoreArrow {
                NSCursor.arrow.set()
            }
        }

        private func nativeHostedInspectorHit(
            at point: NSPoint,
            hostedInspectorHit: HostedInspectorDividerHit
        ) -> NSView? {
            guard let nativeHit = super.hitTest(point), nativeHit !== self else { return nil }
            if nativeHit === hostedInspectorHit.pageView ||
                nativeHit.isDescendant(of: hostedInspectorHit.pageView) {
                return nil
            }
            if nativeHit === hostedInspectorHit.inspectorView ||
                nativeHit.isDescendant(of: hostedInspectorHit.inspectorView) {
                return nativeHit
            }
            if hostedInspectorHit.inspectorView.isDescendant(of: nativeHit),
               !(hostedInspectorHit.pageView === nativeHit || hostedInspectorHit.pageView.isDescendant(of: nativeHit)) {
                return nativeHit
            }
            return nil
        }

        private func hostedInspectorDividerHit(at point: NSPoint) -> HostedInspectorDividerHit? {
            guard let hit = hostedInspectorDividerCandidate(),
                  hostedInspectorDividerHitRect(for: hit).contains(point) else {
                return nil
            }
            return hit
        }

        private func hostedInspectorDividerCandidate() -> HostedInspectorDividerHit? {
            hostedInspectorDividerCandidate(in: self)
        }

        private func hostedInspectorDividerCandidate(in root: NSView) -> HostedInspectorDividerHit? {
            if let preferredHit = hostedInspectorDividerCandidateUsingKnownWebViews(in: root) {
                return preferredHit
            }

            let inspectorCandidates = Self.visibleDescendants(in: root)
                .filter { Self.isVisibleHostedInspectorCandidate($0) && Self.isInspectorView($0) }
                .sorted { lhs, rhs in
                    let lhsFrame = root.convert(lhs.bounds, from: lhs)
                    let rhsFrame = root.convert(rhs.bounds, from: rhs)
                    return lhsFrame.minX < rhsFrame.minX
                }

            var bestHit: HostedInspectorDividerHit?
            var bestScore = -CGFloat.greatestFiniteMagnitude

            for inspectorCandidate in inspectorCandidates {
                guard let candidate = hostedInspectorDividerCandidate(in: root, startingAt: inspectorCandidate) else {
                    continue
                }
                let score = hostedInspectorDividerCandidateScore(candidate)
                if score > bestScore {
                    bestScore = score
                    bestHit = candidate
                }
            }

            return bestHit
        }

        private func hostedInspectorDividerCandidateUsingKnownWebViews(in root: NSView) -> HostedInspectorDividerHit? {
            guard let pageLeaf = hostedWebView,
                  let inspectorLeaf = hostedInspectorFrontendWebView,
                  pageLeaf.isDescendant(of: root),
                  inspectorLeaf.isDescendant(of: root),
                  Self.isVisibleHostedInspectorCandidate(inspectorLeaf) else {
                return nil
            }
            return hostedInspectorDividerCandidate(
                in: root,
                pageLeaf: pageLeaf,
                inspectorLeaf: inspectorLeaf
            )
        }

        private func hostedInspectorDividerCandidate(
            in root: NSView,
            pageLeaf: NSView,
            inspectorLeaf: NSView
        ) -> HostedInspectorDividerHit? {
            var currentInspector: NSView? = inspectorLeaf

            while let inspectorView = currentInspector, inspectorView !== root {
                guard let containerView = inspectorView.superview else { break }
                guard containerView === root || containerView.isDescendant(of: root) else {
                    currentInspector = containerView
                    continue
                }
                guard let pageView = Self.directChild(of: containerView, containing: pageLeaf) else {
                    currentInspector = containerView
                    continue
                }
                guard pageView !== inspectorView,
                      Self.isVisibleHostedInspectorSiblingCandidate(pageView),
                      Self.verticalOverlap(between: pageView.frame, and: inspectorView.frame) > 8,
                      let dockSide = HostedInspectorDockSide.resolve(
                          pageFrame: pageView.frame,
                          inspectorFrame: inspectorView.frame
                      ) else {
                    currentInspector = containerView
                    continue
                }
                return HostedInspectorDividerHit(
                    containerView: containerView,
                    pageView: pageView,
                    inspectorView: inspectorView,
                    dockSide: dockSide
                )
            }

            return nil
        }

        private func hostedInspectorDividerHitRect(for hit: HostedInspectorDividerHit) -> NSRect {
            let pageFrame = convert(hit.pageView.bounds, from: hit.pageView)
            let inspectorFrame = convert(hit.inspectorView.bounds, from: hit.inspectorView)
            return hit.dockSide.dividerHitRect(
                in: bounds,
                pageFrame: pageFrame,
                inspectorFrame: inspectorFrame,
                expansion: Self.hostedInspectorDividerHitExpansion
            )
        }

        private func hostedInspectorDividerCandidate(in root: NSView, startingAt inspectorLeaf: NSView) -> HostedInspectorDividerHit? {
            var current: NSView? = inspectorLeaf
            var bestHit: HostedInspectorDividerHit?

            while let inspectorView = current, inspectorView !== root {
                guard let containerView = inspectorView.superview else { break }

                let pageCandidates = containerView.subviews.compactMap { candidate -> (view: NSView, dockSide: HostedInspectorDockSide)? in
                    guard Self.isVisibleHostedInspectorSiblingCandidate(candidate) else { return nil }
                    guard candidate !== inspectorView else { return nil }
                    guard Self.verticalOverlap(between: candidate.frame, and: inspectorView.frame) > 8 else {
                        return nil
                    }
                    guard let dockSide = HostedInspectorDockSide.resolve(
                        pageFrame: candidate.frame,
                        inspectorFrame: inspectorView.frame
                    ) else {
                        return nil
                    }
                    return (view: candidate, dockSide: dockSide)
                }

                if let pageCandidate = pageCandidates.max(by: {
                    hostedInspectorPageCandidateScore($0.view, inspectorView: inspectorView)
                        < hostedInspectorPageCandidateScore($1.view, inspectorView: inspectorView)
                }) {
                    bestHit = HostedInspectorDividerHit(
                        containerView: containerView,
                        pageView: pageCandidate.view,
                        inspectorView: inspectorView,
                        dockSide: pageCandidate.dockSide
                    )
                }

                current = containerView
            }

            return bestHit
        }

        private func hostedInspectorDividerCandidateScore(_ hit: HostedInspectorDividerHit) -> CGFloat {
            let pageFrame = convert(hit.pageView.bounds, from: hit.pageView)
            let inspectorFrame = convert(hit.inspectorView.bounds, from: hit.inspectorView)
            let overlap = Self.verticalOverlap(between: pageFrame, and: inspectorFrame)
            let coverageWidth = max(pageFrame.maxX, inspectorFrame.maxX) - min(pageFrame.minX, inspectorFrame.minX)
            return (overlap * 1_000) + coverageWidth + pageFrame.width
        }

        private func hostedInspectorPageCandidateScore(_ pageView: NSView, inspectorView: NSView) -> CGFloat {
            let overlap = Self.verticalOverlap(between: pageView.frame, and: inspectorView.frame)
            let coverageWidth = max(pageView.frame.maxX, inspectorView.frame.maxX) - min(pageView.frame.minX, inspectorView.frame.minX)
            return (overlap * 1_000) + coverageWidth + pageView.frame.width
        }

        fileprivate func scheduleHostedInspectorDividerReapply(reason: String) {
            hostedInspectorReapplyWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hostedInspectorReapplyWorkItem = nil
                _ = self.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded()
                if self.hasStoredHostedInspectorWidthPreference {
                    self.reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: reason)
                } else {
                    self.captureHostedInspectorPreferredWidthFromCurrentLayout(reason: reason)
                }
            }
            hostedInspectorReapplyWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func captureHostedInspectorPreferredWidthFromCurrentLayout(reason: String) {
            guard !isApplyingHostedInspectorLayout else { return }
            guard !isHostedInspectorDividerDragActive else { return }
            guard let hit = hostedInspectorDividerCandidate() else {
#if DEBUG
                if !hasLoggedMissingHostedInspectorCandidate {
                    hasLoggedMissingHostedInspectorCandidate = true
                    let preferredWidthDesc = preferredHostedInspectorWidth.map {
                        String(format: "%.1f", $0)
                    } ?? "nil"
                    cmuxDebugLog(
                        "browser.panel.hostedInspector stage=\(reason).captureMissingCandidate " +
                        "host=\(Self.debugObjectID(self)) preferredWidth=\(preferredWidthDesc)"
                    )
                }
#endif
                return
            }

            let inspectorWidth = max(0, hit.inspectorView.frame.width)
            guard inspectorWidth > 1 else { return }
            recordHostedInspectorSideDockWidth(inspectorWidth)
            let currentFraction: CGFloat? = {
                guard hit.containerView.bounds.width > 0 else { return nil }
                return inspectorWidth / hit.containerView.bounds.width
            }()
            let widthMatches = preferredHostedInspectorWidth.map {
                abs($0 - inspectorWidth) <= 0.5
            } ?? false
            let fractionMatches: Bool = {
                switch (preferredHostedInspectorWidthFraction, currentFraction) {
                case (nil, nil):
                    return true
                case let (lhs?, rhs?):
                    return abs(lhs - rhs) <= 0.001
                default:
                    return false
                }
            }()
            guard !(widthMatches && fractionMatches) else { return }

#if DEBUG
            hasLoggedMissingHostedInspectorCandidate = false
#endif
            recordPreferredHostedInspectorWidth(
                inspectorWidth,
                containerBounds: hit.containerView.bounds
            )
        }

        private func reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: String) {
            guard !isApplyingHostedInspectorLayout else { return }
            guard let hit = hostedInspectorDividerCandidate() else { return }
            guard let preferredWidth = resolvedPreferredHostedInspectorWidth(in: hit.containerView.bounds) else {
                return
            }
            let currentInspectorWidth = max(0, hit.inspectorView.frame.width)
            guard abs(currentInspectorWidth - preferredWidth) > 0.5 else { return }
            _ = applyHostedInspectorDividerWidth(
                preferredWidth,
                to: hit,
                minimumInspectorWidth: Self.minimumHostedInspectorWidth,
                reason: reason
            )
        }

        @discardableResult
        private func applyHostedInspectorDividerWidth(
            _ preferredWidth: CGFloat,
            to hit: HostedInspectorDividerHit,
            minimumInspectorWidth: CGFloat,
            reason: String
        ) -> (pageFrame: NSRect, inspectorFrame: NSRect) {
            let containerBounds = hit.containerView.bounds
            let nextFrames = hit.dockSide.resizedFrames(
                preferredWidth: preferredWidth,
                in: containerBounds,
                pageFrame: hit.pageView.frame,
                inspectorFrame: hit.inspectorView.frame,
                minimumInspectorWidth: minimumInspectorWidth
            )
            let pageFrame = nextFrames.pageFrame
            let inspectorFrame = nextFrames.inspectorFrame

            let oldPageFrame = hit.pageView.frame
            let oldInspectorFrame = hit.inspectorView.frame
            let pageChanged = !Self.rectApproximatelyEqual(pageFrame, oldPageFrame, epsilon: 0.5)
            let inspectorChanged = !Self.rectApproximatelyEqual(inspectorFrame, oldInspectorFrame, epsilon: 0.5)
            guard pageChanged || inspectorChanged else {
                return (pageFrame, inspectorFrame)
            }
            recordHostedInspectorSideDockWidth(inspectorFrame.width)

            isApplyingHostedInspectorLayout = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hit.pageView.frame = pageFrame
            hit.inspectorView.frame = inspectorFrame
            CATransaction.commit()
            isApplyingHostedInspectorLayout = false

            hit.pageView.needsDisplay = true
            hit.pageView.setNeedsDisplay(hit.pageView.bounds)
            hit.inspectorView.needsDisplay = true
            hit.inspectorView.setNeedsDisplay(hit.inspectorView.bounds)
            hit.containerView.needsDisplay = true
            hit.containerView.setNeedsDisplay(hit.containerView.bounds)
            if let localInlineSlotView {
                localInlineSlotView.needsDisplay = true
                localInlineSlotView.setNeedsDisplay(localInlineSlotView.bounds)
            }
            needsDisplay = true
            setNeedsDisplay(bounds)

            let isLiveDrag = reason == "drag"
#if DEBUG
            cmuxDebugLog(
                "browser.panel.hostedInspector stage=\(reason).reapply " +
                "host=\(Self.debugObjectID(self)) preferredWidth=\(String(format: "%.1f", preferredWidth)) " +
                "liveDrag=\(isLiveDrag ? 1 : 0) " +
                "pageChanged=\(pageChanged ? 1 : 0) inspectorChanged=\(inspectorChanged ? 1 : 0) " +
                "oldPage=\(Self.debugRect(oldPageFrame)) oldInspector=\(Self.debugRect(oldInspectorFrame)) " +
                "container=\(Self.debugObjectID(hit.containerView)) " +
                "pageFrame=\(Self.debugRect(pageFrame)) inspectorFrame=\(Self.debugRect(inspectorFrame))"
            )
#endif
            return (pageFrame, inspectorFrame)
        }

        private static func visibleDescendants(in root: NSView) -> [NSView] {
            var descendants: [NSView] = []
            var stack = Array(root.subviews.reversed())
            while let view = stack.popLast() {
                descendants.append(view)
                stack.append(contentsOf: view.subviews.reversed())
            }
            return descendants
        }

        private static func directChild(of container: NSView, containing descendant: NSView) -> NSView? {
            var current: NSView? = descendant
            var directChild: NSView?
            while let view = current, view !== container {
                directChild = view
                current = view.superview
            }
            guard current === container else { return nil }
            return directChild
        }

        fileprivate static func isInspectorView(_ view: NSView) -> Bool {
            cmuxIsWebInspectorObject(view)
        }

        fileprivate static func isVisibleHostedInspectorCandidate(_ view: NSView) -> Bool {
            !view.isHidden &&
                view.alphaValue > 0 &&
                view.frame.width > 1 &&
                view.frame.height > 1
        }

        private static func isVisibleHostedInspectorSiblingCandidate(_ view: NSView) -> Bool {
            !view.isHidden &&
                view.alphaValue > 0 &&
                view.frame.height > 1
        }

        private static func verticalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
            max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
        }
    }

    #if DEBUG
    private static func logDevToolsState(
        _ panel: BrowserPanel,
        event: String,
        generation: Int,
        retryCount: Int,
        details: String? = nil
    ) {
        var line = "browser.devtools event=\(event) panel=\(panel.id.uuidString.prefix(5)) generation=\(generation) retry=\(retryCount) \(panel.debugDeveloperToolsStateSummary())"
        if let details, !details.isEmpty {
            line += " \(details)"
        }
        cmuxDebugLog(line)
    }

    private static func objectID(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private static func responderDescription(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return "\(type(of: responder))@\(objectID(responder))"
    }

    private static func rectDescription(_ rect: NSRect) -> String {
        String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    private static func attachContext(webView: WKWebView, host: NSView) -> String {
        let hostWindow = host.window?.windowNumber ?? -1
        let webWindow = webView.window?.windowNumber ?? -1
        let firstResponder = (webView.window ?? host.window)?.firstResponder
        return "host=\(objectID(host)) hostWin=\(hostWindow) hostInWin=\(host.window == nil ? 0 : 1) hostFrame=\(rectDescription(host.frame)) hostBounds=\(rectDescription(host.bounds)) oldSuper=\(objectID(webView.superview)) webWin=\(webWindow) webInWin=\(webView.window == nil ? 0 : 1) webFrame=\(rectDescription(webView.frame)) webHidden=\(webView.isHidden ? 1 : 0) fr=\(responderDescription(firstResponder))"
    }
    #endif

    private static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }

    private static func isLikelyInspectorResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if cmuxIsWebInspectorObject(responder) {
            return true
        }
        guard let view = responder as? NSView else { return false }
        var node: NSView? = view
        var hops = 0
        while let current = node, hops < 64 {
            if cmuxIsWebInspectorObject(current) {
                return true
            }
            node = current.superview
            hops += 1
        }
        return false
    }

    private static func firstResponderResignState(
        _ responder: NSResponder?,
        webView: WKWebView
    ) -> (needsResign: Bool, flags: String) {
        let inWebViewChain = responderChainContains(responder, target: webView)
        let inspectorResponder = isLikelyInspectorResponder(responder)
        let needsResign = inWebViewChain || inspectorResponder
        return (
            needsResign: needsResign,
            flags: "frInWebChain=\(inWebViewChain ? 1 : 0) frIsInspector=\(inspectorResponder ? 1 : 0)"
        )
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

    private static func clearPortalCallbacks(for host: NSView) {
        guard let host = host as? HostContainerView else { return }
        host.onDidMoveToWindow = nil
        host.onGeometryChanged = nil
        host.clearLocalInlineCallbacks()
    }

    private static func shouldPreserveExternalFullscreenHost(
        for webView: WKWebView,
        relativeTo expectedWindow: NSWindow?
    ) -> Bool {
        webView.cmuxIsManagedByExternalFullscreenWindow(relativeTo: expectedWindow)
    }

    private static func localInlineTransferRoot(for webView: WKWebView) -> NSView? {
        var current = webView.superview
        var last: NSView?
        while let view = current {
            if view is WindowBrowserSlotView {
                return view
            }
            if view is HostContainerView {
                break
            }
            last = view
            current = view.superview
        }
        return last ?? webView.superview
    }

    private static func directTransferChild(of container: NSView, containing descendant: NSView) -> NSView? {
        var current: NSView? = descendant
        var directChild: NSView?
        while let view = current, view !== container {
            directChild = view
            current = view.superview
        }
        guard current === container else { return nil }
        return directChild
    }

    private static func relatedWebKitTransferSubviews(
        from sourceSuperview: NSView,
        primaryWebView: WKWebView
    ) -> [NSView] {
        var relatedSubviews: [NSView] = []
        var seen = Set<ObjectIdentifier>()
        let inspectorFrontend = primaryWebView.cmuxInspectorFrontendWebView()

        func append(_ candidate: NSView?) {
            guard let candidate, candidate !== sourceSuperview else { return }
            let id = ObjectIdentifier(candidate)
            guard seen.insert(id).inserted else { return }
            relatedSubviews.append(candidate)
        }

        func containsInspectorFrontend(_ candidate: NSView) -> Bool {
            guard let inspectorFrontend else { return false }
            return candidate === inspectorFrontend || inspectorFrontend.isDescendant(of: candidate)
        }

        if let directChild = directTransferChild(of: sourceSuperview, containing: primaryWebView),
           !containsInspectorFrontend(directChild) {
            append(directChild)
        } else {
            append(primaryWebView)
        }

        for view in sourceSuperview.subviews {
            if view === primaryWebView { continue }
            let className = String(describing: type(of: view))
            if containsInspectorFrontend(view) {
#if DEBUG
                cmuxDebugLog(
                    "browser.localHost.reparent.skipInspectorFrontend " +
                    "view=\(Self.objectID(view)) class=\(className)"
                )
#endif
                continue
            }
            if cmuxIsWebInspectorClassName(className) || cmuxIsWebInspectorObject(view) {
                continue
            }
            guard className.contains("WK") else { continue }
            append(view)
        }

        return relatedSubviews
    }

    private static func moveWebKitRelatedSubviewsIntoHostIfNeeded(
        from sourceSuperview: NSView,
        to container: WindowBrowserSlotView,
        primaryWebView: WKWebView,
        reason: String
    ) {
        let relatedSubviews = relatedWebKitTransferSubviews(
            from: sourceSuperview,
            primaryWebView: primaryWebView
        )
        guard !relatedSubviews.isEmpty else { return }
        let preserveSlotLocalFrames = sourceSuperview is WindowBrowserSlotView
        let sourceSlotBoundsSize = sourceSuperview.bounds.size
        var movedSubviewCount = 0
        var reusedSourceLocalFrames = false
#if DEBUG
        cmuxDebugLog(
            "browser.localHost.reparent.batch reason=\(reason) source=\(Self.objectID(sourceSuperview)) " +
            "container=\(Self.objectID(container)) count=\(relatedSubviews.count) " +
            "sourceType=\(String(describing: type(of: sourceSuperview))) targetType=\(String(describing: type(of: container)))"
        )
#endif
        for view in relatedSubviews {
            if view === container || view.isDescendant(of: container) {
                continue
            }
            let className = String(describing: type(of: view))
            let targetFrame: NSRect
            let currentSuperview = view.superview
            if preserveSlotLocalFrames && currentSuperview === sourceSuperview {
                targetFrame = view.frame
                reusedSourceLocalFrames = true
            } else {
                let frameInWindow = currentSuperview?.convert(view.frame, to: nil)
                    ?? sourceSuperview.convert(view.frame, to: nil)
                targetFrame = container.convert(frameInWindow, from: nil)
            }
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: nil)
            view.frame = targetFrame
            movedSubviewCount += 1
#if DEBUG
            cmuxDebugLog(
                "browser.localHost.reparent.batch.item reason=\(reason) class=\(className) " +
                "view=\(Self.objectID(view))"
            )
#endif
        }
        guard movedSubviewCount > 0 else { return }
        if reusedSourceLocalFrames, sourceSlotBoundsSize != container.bounds.size {
            container.resizeSubviews(withOldSize: sourceSlotBoundsSize)
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }
    }

    private static func installPortalAnchorView(_ anchorView: NSView, in host: NSView) {
        // SwiftUI can keep transient replacement hosts alive off-window during split
        // reparenting. Never let those hosts steal the shared portal anchor, or the
        // portal will bind against an anchor with no real window and WKWebView will
        // fall into a hidden/unrendered state.
        guard host.window != nil else { return }
        if anchorView.superview !== host {
            anchorView.removeFromSuperview()
            anchorView.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(anchorView)
            NSLayoutConstraint.activate([
                anchorView.topAnchor.constraint(equalTo: host.topAnchor),
                anchorView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                anchorView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                anchorView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        } else if anchorView.translatesAutoresizingMaskIntoConstraints {
            anchorView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                anchorView.topAnchor.constraint(equalTo: host.topAnchor),
                anchorView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                anchorView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                anchorView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        }
        host.layoutSubtreeIfNeeded()
    }

    private func schedulePortalLifecycleVisibilityUpdate(
        coordinator: Coordinator,
        generation: Int,
        visibleInUI: Bool,
        reason: String,
        requireDesiredVisibilityMatch: Bool = true
    ) {
        let browserPanel = panel
        Task { @MainActor [weak coordinator] in
            guard let coordinator else { return }
            guard coordinator.attachGeneration == generation else { return }
            guard !requireDesiredVisibilityMatch ||
                coordinator.desiredPortalVisibleInUI == visibleInUI else { return }
            browserPanel.noteWebViewVisibility(visibleInUI, reason: reason)
        }
    }

    private func updateUsingLocalInlineHosting(_ nsView: NSView, context: Context, webView: WKWebView) -> Bool {
        guard let host = nsView as? HostContainerView else { return false }
        let slotView = host.ensureLocalInlineSlotView()
        let isAlreadyInLocalHost = host.containsManagedLocalInlineContent(webView)
        let shouldPreserveExternalFullscreenHost = Self.shouldPreserveExternalFullscreenHost(
            for: webView,
            relativeTo: host.window
        )
        let didAttachWebViewToLocalHost =
            !isAlreadyInLocalHost && !shouldPreserveExternalFullscreenHost

        let coordinator = context.coordinator
        coordinator.desiredPortalVisibleInUI = false
        coordinator.desiredPortalZPriority = 0
        coordinator.attachGeneration += 1

        if panel.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(host),
            reason: "localInlineHosting"
        ) {
            BrowserWindowPortalRegistry.discard(
                webView: webView,
                source: "viewStateChanged.localInlineHosting",
                preserveCurrentSuperview: true
            )
        }

        let shouldPreserveExistingExternalLocalHost =
            host.window == nil &&
            webView.superview != nil &&
            !host.containsManagedLocalInlineContent(webView)
        if shouldPreserveExistingExternalLocalHost {
            // Split zoom can instantiate a replacement local host before it joins a window.
            // Never let that off-window host steal the live page + inspector hierarchy away
            // from the currently visible local host.
            host.setLocalInlineSlotHidden(true)
            coordinator.lastPortalHostId = nil
            coordinator.lastSynchronizedHostGeometryRevision = 0
#if DEBUG
            cmuxDebugLog(
                "browser.localHost.reparent.skip web=\(Self.objectID(webView)) " +
                "reason=offWindowReplacementHost super=\(Self.objectID(webView.superview)) " +
                "host=\(Self.objectID(host)) slot=\(Self.objectID(slotView))"
            )
            Self.logDevToolsState(
                panel,
                event: "localHost.skip",
                generation: coordinator.attachGeneration,
                retryCount: 0,
                details: Self.attachContext(webView: webView, host: host)
            )
#endif
            return false
        }

#if DEBUG
        if shouldPreserveExternalFullscreenHost {
            cmuxDebugLog(
                "browser.localHost.reparent.skip web=\(Self.objectID(webView)) " +
                "reason=fullscreenExternalHost host=\(Self.objectID(host)) " +
                "slot=\(Self.objectID(slotView)) state=\(String(describing: webView.fullscreenState))"
            )
        }
#endif

        let preferredAttachedWidthState = panel.preferredAttachedDeveloperToolsWidthState()
        host.setPreferredHostedInspectorWidth(
            width: preferredAttachedWidthState.width,
            widthFraction: preferredAttachedWidthState.widthFraction
        )
        host.setHostedInspectorFrontendWebView(webView.cmuxInspectorFrontendWebView())
        host.onPreferredHostedInspectorWidthChanged = { [weak browserPanel = panel] width, _ in
            guard let browserPanel else { return }
            browserPanel.recordPreferredAttachedDeveloperToolsWidth(
                width,
                containerBounds: slotView.bounds
            )
        }
        slotView.onHostedInspectorLayout = { [weak host] _ in
            host?.scheduleHostedInspectorDividerReapply(reason: "slot.layout")
            host?.scheduleHostedInspectorDockConfigurationSync(reason: "slot.layout")
        }

        if didAttachWebViewToLocalHost {
            if let sourceSuperview = Self.localInlineTransferRoot(for: webView) {
                Self.moveWebKitRelatedSubviewsIntoHostIfNeeded(
                    from: sourceSuperview,
                    to: slotView,
                    primaryWebView: webView,
                    reason: "attachLocalHost"
                )
            } else {
                slotView.addSubview(webView, positioned: .above, relativeTo: nil)
            }
        }

        slotView.isHidden = false
        host.pinHostedWebView(
            webView,
            in: host.currentHostedWebViewContainer(preferredSlotView: slotView)
        )
        // Local-inline hosting takes ownership of the live WKWebView hierarchy.
        // Drop any stale portal entry once local-inline hosting owns the live
        // WKWebView hierarchy so deferred portal recovery cannot mutate the
        // browser after workspace switches.
        BrowserWindowPortalRegistry.discard(
            webView: webView,
            source: "viewStateChanged.localInlineHosting",
            preserveCurrentSuperview: true
        )
        coordinator.lastPortalHostId = nil
        coordinator.lastSynchronizedHostGeometryRevision = 0
        if host.window != nil && !shouldPreserveExternalFullscreenHost {
            let wasDeveloperToolsVisible = panel.isDeveloperToolsVisible()
            panel.noteDeveloperToolsHostAttached()
            panel.restoreDeveloperToolsAfterAttachIfNeeded()
            if let sourceSuperview = Self.localInlineTransferRoot(for: webView),
               didAttachWebViewToLocalHost || sourceSuperview === slotView {
                Self.moveWebKitRelatedSubviewsIntoHostIfNeeded(
                    from: sourceSuperview,
                    to: slotView,
                    primaryWebView: webView,
                    reason: didAttachWebViewToLocalHost
                        ? "localInline.reconcile.immediate"
                        : "localInline.reconcile.existingHost"
                )
            }
            host.setHostedInspectorFrontendWebView(webView.cmuxInspectorFrontendWebView())
            let didRevealDeveloperToolsAfterAttach =
                !wasDeveloperToolsVisible && panel.isDeveloperToolsVisible()
            webView.needsLayout = true
            webView.layoutSubtreeIfNeeded()
            slotView.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.refreshHostedWebKitPresentation(
                reason: didAttachWebViewToLocalHost
                    ? "localInline.update.immediate"
                    : "localInline.update.existingHost",
                forceLifecycleRefresh: didRevealDeveloperToolsAfterAttach
            )
            host.normalizeHostedInspectorLayoutIfNeeded(
                reason: didAttachWebViewToLocalHost
                    ? "localInline.update.immediate"
                    : "localInline.update.existingHost"
            )
            host.scheduleHostedInspectorDividerReapply(
                reason: didAttachWebViewToLocalHost
                    ? "localInline.update.sync"
                    : "localInline.update.existingHost"
            )
            DispatchQueue.main.async { [weak host, weak webView] in
                guard let host, let webView else { return }
#if DEBUG
                let slotFrame = host.localInlineSlotViewForDebug()?.frame ?? .zero
                let companions = webView.superview?.subviews
                    .filter { $0 !== webView }
                    .map { String(describing: type(of: $0)) }
                    .joined(separator: ",") ?? "-"
                cmuxDebugLog(
                    "browser.localInline.frames host=\(host.bounds) slot=\(slotFrame) " +
                    "web=\(webView.frame) webSuper=\(String(describing: type(of: webView.superview))) " +
                    "inspector=\(webView.cmuxInspectorFrontendWebView() != nil ? 1 : 0) " +
                    "companions=\(companions)"
                )
#endif
                if let sourceSuperview = Self.localInlineTransferRoot(for: webView),
                   sourceSuperview === slotView {
                    Self.moveWebKitRelatedSubviewsIntoHostIfNeeded(
                        from: sourceSuperview,
                        to: slotView,
                        primaryWebView: webView,
                        reason: "localInline.reconcile.async"
                    )
                }
                host.setHostedInspectorFrontendWebView(webView.cmuxInspectorFrontendWebView())
                host.refreshHostedWebKitPresentation(
                    reason: didAttachWebViewToLocalHost
                        ? "localInline.update.async"
                        : "localInline.update.existingHost.async",
                    forceLifecycleRefresh: didRevealDeveloperToolsAfterAttach
                )
                host.scheduleHostedInspectorDockConfigurationSync(
                    reason: didAttachWebViewToLocalHost
                        ? "localInline.update.async"
                        : "localInline.update.existingHost.async"
                )
            }
        } else if !shouldPreserveExternalFullscreenHost {
            panel.consumeAttachedDeveloperToolsManualCloseIfNeeded()
            host.scheduleHostedInspectorDockConfigurationSync(reason: "localInline.update")
        }

#if DEBUG
        Self.logDevToolsState(
            panel,
            event: "localHost.update",
            generation: coordinator.attachGeneration,
            retryCount: 0,
            details: Self.attachContext(webView: webView, host: host)
        )
#endif
        return !shouldPreserveExternalFullscreenHost
    }

    private func updateUsingWindowPortal(_ nsView: NSView, context: Context, webView: WKWebView) -> Bool {
        guard let host = nsView as? HostContainerView else { return false }
        if panel.shouldUseLocalInlineDeveloperToolsHosting() {
            host.clearStaleHostedInspectorOwnershipState()
            host.releaseHostedWebViewConstraints()
            let hostId = ObjectIdentifier(host)
            if panel.releasePortalHostIfOwned(
                hostId: hostId,
                reason: "windowPortalSuppressedForLocalInlineHosting"
            ) {
                BrowserWindowPortalRegistry.discard(
                    webView: webView,
                    source: "viewStateChanged.windowPortalSuppressedForLocalInlineHosting",
                    preserveCurrentSuperview: true
                )
            }
            return false
        }
        host.prepareForWindowPortalHosting()
        host.setLocalInlineSlotHidden(true)
        host.releaseHostedWebViewConstraints()
        let shouldPreserveExternalFullscreenHost = Self.shouldPreserveExternalFullscreenHost(
            for: webView,
            relativeTo: host.window
        )

        let coordinator = context.coordinator
        let paneDropContext = currentPaneDropContext()
        let isCurrentPaneOwner = paneDropContext?.paneId.id == paneId.id
        let hostId = ObjectIdentifier(host)
        let previousVisible = coordinator.desiredPortalVisibleInUI
        let previousZPriority = coordinator.desiredPortalZPriority
        coordinator.desiredPortalVisibleInUI = shouldAttachWebView && isCurrentPaneOwner
        coordinator.desiredPortalZPriority = portalZPriority
        coordinator.attachGeneration += 1
        let generation = coordinator.attachGeneration
        let activePaneDropContext = coordinator.desiredPortalVisibleInUI ? paneDropContext : nil
        let activeSearchOverlay = coordinator.desiredPortalVisibleInUI ? searchOverlay : nil
        let portalAnchorView = panel.portalAnchorView
        let portalHideReason = !isCurrentPaneOwner ? "lostPaneOwnership" : "hidden"
        let didReleasePortalHost: Bool
        if !shouldAttachWebView || !isCurrentPaneOwner {
            didReleasePortalHost = panel.releasePortalHostIfOwned(
                hostId: hostId,
                reason: portalHideReason
            )
            // Only the host that currently owns the portal is allowed to hide it.
            // Older keep-alive hosts can still receive updates after a new owner binds.
            if didReleasePortalHost {
                BrowserWindowPortalRegistry.hide(
                    webView: webView,
                    source: "viewStateChanged.\(portalHideReason)"
                )
            }
        } else {
            didReleasePortalHost = false
        }
        let portalHostAccepted =
            shouldAttachWebView &&
            isCurrentPaneOwner &&
            panel.claimPortalHost(
                hostId: hostId,
                paneId: paneId,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "update"
            )
        if portalHostAccepted || didReleasePortalHost {
            let lifecycleVisibleInUI = portalHostAccepted && coordinator.desiredPortalVisibleInUI
            let lifecycleReason = lifecycleVisibleInUI ? "portal.update.visible" : "portal.update.hidden"
            schedulePortalLifecycleVisibilityUpdate(
                coordinator: coordinator,
                generation: generation,
                visibleInUI: lifecycleVisibleInUI,
                reason: lifecycleReason,
                requireDesiredVisibilityMatch: portalHostAccepted
            )
        }
#if DEBUG
        if !isCurrentPaneOwner && (shouldAttachWebView || host.window != nil) {
            cmuxDebugLog(
                "browser.portal.owner.skip panel=\(panel.id.uuidString.prefix(5)) " +
                "viewPane=\(paneId.id.uuidString.prefix(5)) " +
                "currentPane=\(paneDropContext?.paneId.id.uuidString.prefix(5) ?? "nil") " +
                "host=\(Self.objectID(host)) hostInWin=\(host.window != nil ? 1 : 0) " +
                "released=\(didReleasePortalHost ? 1 : 0)"
            )
        }
#endif
        if host.window != nil, portalHostAccepted {
            Self.installPortalAnchorView(portalAnchorView, in: host)
        }
        let activeOmnibarSuggestions = coordinator.desiredPortalVisibleInUI ? omnibarSuggestions : nil

        host.onDidMoveToWindow = { [weak host, weak webView, weak coordinator, weak portalAnchorView, weak browserPanel = panel] in
            guard let host, let webView, let coordinator, let portalAnchorView, let browserPanel else { return }
            guard coordinator.attachGeneration == generation else { return }
            guard currentPaneDropContext()?.paneId.id == paneId.id else { return }
            guard browserPanel.claimPortalHost(
                hostId: ObjectIdentifier(host),
                paneId: paneId,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "didMoveToWindow"
            ) else { return }
            guard host.window != nil else { return }
            Self.installPortalAnchorView(portalAnchorView, in: host)
            BrowserWindowPortalRegistry.bind(
                webView: webView,
                to: portalAnchorView,
                visibleInUI: coordinator.desiredPortalVisibleInUI,
                zPriority: coordinator.desiredPortalZPriority
            )
            BrowserWindowPortalRegistry.refresh(
                webView: webView,
                reason: "portalHostBind.didMoveToWindow"
            )
            BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                for: webView,
                height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
            )
            BrowserWindowPortalRegistry.updatePaneDropContext(for: webView, context: activePaneDropContext)
            BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
            BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: activeOmnibarSuggestions)
            coordinator.lastPortalHostId = ObjectIdentifier(host)
            coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
        }
        host.onGeometryChanged = { [weak host, weak webView, weak coordinator, weak portalAnchorView, weak browserPanel = panel] in
            guard let host, let webView, let coordinator, let portalAnchorView, let browserPanel else { return }
            guard coordinator.attachGeneration == generation else { return }
            guard currentPaneDropContext()?.paneId.id == paneId.id else { return }
            guard browserPanel.claimPortalHost(
                hostId: ObjectIdentifier(host),
                paneId: paneId,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "geometryChanged"
            ) else { return }
            guard host.window != nil else { return }
            let hostId = ObjectIdentifier(host)
            Self.installPortalAnchorView(portalAnchorView, in: host)
            if coordinator.lastPortalHostId != hostId ||
               !BrowserWindowPortalRegistry.isWebView(webView, boundTo: portalAnchorView) {
                BrowserWindowPortalRegistry.bind(
                    webView: webView,
                    to: portalAnchorView,
                    visibleInUI: coordinator.desiredPortalVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority
                )
                BrowserWindowPortalRegistry.refresh(
                    webView: webView,
                    reason: "portalHostBind.geometryChanged"
                )
                BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                    for: webView,
                    height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
                )
                BrowserWindowPortalRegistry.updatePaneDropContext(for: webView, context: activePaneDropContext)
                BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
                BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: activeOmnibarSuggestions)
                coordinator.lastPortalHostId = hostId
            }
            BrowserWindowPortalRegistry.synchronizeForAnchor(portalAnchorView)
            coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
        }

        if !shouldAttachWebView {
            // In portal mode we no longer detach/re-attach to preserve DevTools state.
            // Sync the inspector preference directly so manual closes are respected.
            panel.syncDeveloperToolsPreferenceFromInspector(
                preserveVisibleIntent: panel.shouldPreserveDeveloperToolsIntentWhileDetached()
            )
        }

        if host.window != nil, portalHostAccepted {
            let geometryRevision = host.geometryRevision
            let portalEntryMissing = !BrowserWindowPortalRegistry.isWebView(webView, boundTo: portalAnchorView)
            let shouldBindNow =
                coordinator.lastPortalHostId != hostId ||
                webView.superview == nil ||
                portalEntryMissing ||
                previousVisible != shouldAttachWebView ||
                previousZPriority != portalZPriority
            if shouldBindNow {
                Self.installPortalAnchorView(portalAnchorView, in: host)
                BrowserWindowPortalRegistry.bind(
                    webView: webView,
                    to: portalAnchorView,
                    visibleInUI: coordinator.desiredPortalVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority
                )
                // Force a rendering-state reattach after portal host replacement
                // (e.g. after a pane split). Without this, WKWebView can freeze
                // because _exitInWindow/_enterInWindow are never cycled when the
                // web view is reparented to a new container during bind.
                BrowserWindowPortalRegistry.refresh(
                    webView: webView,
                    reason: "portalHostBind"
                )
                coordinator.lastPortalHostId = hostId
                coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
            }
            BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                for: webView,
                height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
            )
            BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
            BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: activeOmnibarSuggestions)
            if !shouldBindNow,
               coordinator.lastSynchronizedHostGeometryRevision != geometryRevision {
                BrowserWindowPortalRegistry.synchronizeForAnchor(portalAnchorView)
                coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
            }
        } else if portalHostAccepted {
            // Bind is deferred until host moves into a window. Keep the current
            // portal entry's desired state in sync so stale callbacks cannot keep
            // the previous anchor visible while this host is temporarily off-window.
            BrowserWindowPortalRegistry.updateEntryVisibility(
                for: webView,
                visibleInUI: coordinator.desiredPortalVisibleInUI,
                zPriority: coordinator.desiredPortalZPriority
            )
        }

        if portalHostAccepted {
            BrowserWindowPortalRegistry.updateDropZoneOverlay(
                for: webView,
                zone: coordinator.desiredPortalVisibleInUI ? paneDropZone : nil
            )
            BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                for: webView,
                height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
            )
            BrowserWindowPortalRegistry.updatePaneDropContext(
                for: webView,
                context: activePaneDropContext
            )
            BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
            BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: activeOmnibarSuggestions)
        }

        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        #if DEBUG
        Self.logDevToolsState(
            panel,
            event: "portal.update",
            generation: coordinator.attachGeneration,
            retryCount: 0,
            details: Self.attachContext(webView: webView, host: host)
        )
        #endif
        return portalHostAccepted && !shouldPreserveExternalFullscreenHost
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let webView = panel.webView
        let coordinator = context.coordinator
        let isCurrentPaneOwner = currentPaneDropContext()?.paneId.id == paneId.id
        if let previousWebView = coordinator.webView, previousWebView !== webView {
            BrowserWindowPortalRegistry.detach(webView: previousWebView)
            coordinator.lastPortalHostId = nil
            coordinator.lastSynchronizedHostGeometryRevision = 0
        }
        coordinator.panel = panel
        coordinator.webView = webView

        Self.clearPortalCallbacks(for: nsView)
        let hostOwnsPortal = useLocalInlineHosting
            ? updateUsingLocalInlineHosting(nsView, context: context, webView: webView)
            : updateUsingWindowPortal(nsView, context: context, webView: webView)
        if hostOwnsPortal {
            panel.releaseBackgroundPreloadHostIfAttachedToRealWindow(reason: "representable.update")
        }
        Self.applyWebViewFirstResponderPolicy(
            panel: panel,
            webView: webView,
            isPanelFocused: isPanelFocused && isCurrentPaneOwner && hostOwnsPortal
        )

        Self.applyFocus(
            panel: panel,
            webView: webView,
            nsView: nsView,
            shouldFocusWebView: shouldFocusWebView && isCurrentPaneOwner && hostOwnsPortal,
            isPanelFocused: isPanelFocused && isCurrentPaneOwner && hostOwnsPortal
        )
    }

    private static func applyFocus(
        panel: BrowserPanel,
        webView: WKWebView,
        nsView: NSView,
        shouldFocusWebView: Bool,
        isPanelFocused: Bool
    ) {
        // Focus handling. Avoid fighting the address bar when it is focused.
        guard let window = nsView.window else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                "action=skip reason=no_window shouldFocus=\(shouldFocusWebView ? 1 : 0) " +
                "panelFocused=\(isPanelFocused ? 1 : 0)"
            )
#endif
            return
        }
        if isPanelFocused && responderChainContains(window.firstResponder, target: webView) {
            if panel.shouldSuppressWebViewFocus() {
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                    "action=skip_webview_intent reason=suppressed_first_responder_chain"
                )
#endif
            } else {
                panel.noteWebViewFocused()
            }
        }
        if shouldFocusWebView {
            if panel.shouldSuppressWebViewFocus() {
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                    "action=skip reason=suppressed panelFocused=\(isPanelFocused ? 1 : 0)"
                )
#endif
                return
            }
            if responderChainContains(window.firstResponder, target: webView) {
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                    "action=skip reason=already_first_responder_chain"
                )
#endif
                return
            }
            let result = window.makeFirstResponder(webView)
            if result {
                panel.noteWebViewFocused()
            }
#if DEBUG
            cmuxDebugLog(
                "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                "action=focus result=\(result ? 1 : 0) fr=\(responderDescription(window.firstResponder))"
            )
#endif
        } else if !isPanelFocused && responderChainContains(window.firstResponder, target: webView) {
            // Only force-resign WebView focus when this panel itself is not focused.
            // If the panel is focused but the omnibar-focus state is briefly stale, aggressively
            // clearing first responder here can undo programmatic webview focus (socket tests).
            let result = window.makeFirstResponder(nil)
#if DEBUG
            cmuxDebugLog(
                "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                "action=resign result=\(result ? 1 : 0) fr=\(responderDescription(window.firstResponder))"
            )
#endif
        }
    }

    private static func applyWebViewFirstResponderPolicy(
        panel: BrowserPanel,
        webView: WKWebView,
        isPanelFocused: Bool
    ) {
        guard let cmuxWebView = webView as? CmuxWebView else { return }
        let next = isPanelFocused && !panel.shouldSuppressWebViewFocus()
        if cmuxWebView.allowsFirstResponderAcquisition != next {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.policy panel=\(panel.id.uuidString.prefix(5)) " +
                "web=\(ObjectIdentifier(cmuxWebView)) old=\(cmuxWebView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "new=\(next ? 1 : 0) isPanelFocused=\(isPanelFocused ? 1 : 0) " +
                "suppress=\(panel.shouldSuppressWebViewFocus() ? 1 : 0)"
            )
#endif
        }
        cmuxWebView.allowsFirstResponderAcquisition = next
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attachGeneration += 1
        clearPortalCallbacks(for: nsView)
        if let panel = coordinator.panel, let host = nsView as? HostContainerView {
            panel.releasePortalHostIfOwned(
                hostId: ObjectIdentifier(host),
                reason: "dismantle"
            )
        }

        guard let webView = coordinator.webView else { return }
        let panel = coordinator.panel

        // If we're being torn down while the WKWebView (or one of its subviews) is first responder,
        // resign it before detaching.
        let window = webView.window ?? nsView.window
        if let window {
            let state = firstResponderResignState(window.firstResponder, webView: webView)
            if state.needsResign {
                #if DEBUG
                if let panel {
                    logDevToolsState(
                        panel,
                        event: "dismantle.resignFirstResponder",
                        generation: coordinator.attachGeneration,
                        retryCount: 0,
                        details: attachContext(webView: webView, host: nsView) + " " + state.flags
                    )
                }
                #endif
                window.makeFirstResponder(nil)
            }
        }

        // SwiftUI can transiently dismantle/rebuild the browser host view during split
        // rearrangement. Do not detach the portal-hosted WKWebView or clear its pane-drop
        // context here; explicit teardown still happens on real web view replacement and
        // panel teardown, and preserving this state lets internal tab drags re-enter the
        // browser pane while SwiftUI churns underneath.
        BrowserWindowPortalRegistry.updateDropZoneOverlay(for: webView, zone: nil)
        coordinator.lastPortalHostId = nil
        coordinator.lastSynchronizedHostGeometryRevision = 0
    }

    private func currentPaneDropContext() -> BrowserPaneDropContext? {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == panel.workspaceId }),
              let paneId = workspace.paneId(forPanelId: panel.id) else {
            return nil
        }
        return BrowserPaneDropContext(
            workspaceId: panel.workspaceId,
            panelId: panel.id,
            paneId: paneId
        )
    }
}
