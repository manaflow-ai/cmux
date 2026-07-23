import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxAppKitSupportUI
import CmuxArtifacts
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

enum RightSidebarContentMountPolicy {
    static func shouldMountContent(isRightSidebarVisible: Bool, hasMountedContent: Bool) -> Bool {
        isRightSidebarVisible || hasMountedContent
    }
}

enum FileExplorerRootSyncPolicy {
    static func shouldSyncFileExplorerStore(isRightSidebarVisible: Bool, mode: RightSidebarMode) -> Bool {
        guard isRightSidebarVisible else { return false }
        switch mode {
        case .files, .find:
            return true
        case .sessions, .artifacts, .feed, .dock, .customSidebar:
            return false
        }
    }
}

/// Right sidebar root view. Hosts a segmented mode picker plus the active panel.
struct RightSidebarPanelView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var fileExplorerStore: FileExplorerStore
    @ObservedObject var fileExplorerState: FileExplorerState
    @ObservedObject var sessionIndexStore: SessionIndexStore
    let titlebarHeight: CGFloat
    let windowAppearance: WindowAppearanceSnapshot
    let workspaceId: UUID?
    let artifactWorkspace: ArtifactSidebarWorkspace?
    let onResumeSession: ((SessionEntry) -> Void)?
    let onOpenFilePreview: (String) -> Void
    let onOpenArtifact: (ArtifactSidebarRowSnapshot) -> Void
    let onOpenAsPane: (RightSidebarMode) -> Void
    let onClose: () -> Void

    @State private var modeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOrControl) { window in
        guard let responder = window.firstResponder else { return false }
        return AppDelegate.shared?.isRightSidebarFocusResponder(responder, in: window) == true
    }
    @State private var focusShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @State private var closeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @State private var hasMountedRightSidebarContent = false
    @State private var artifactSidebarModel: ArtifactSidebarModel
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    private let alwaysShowShortcutHints = ShortcutHintDebugSettings().alwaysShowHints
    private let closeShortcutHintXOffset = ShortcutHintDebugSettings.defaultRightSidebarCloseHintX
    private let closeShortcutHintYOffset = ShortcutHintDebugSettings.defaultRightSidebarCloseHintY
    private let focusShortcutHintXOffset = ShortcutHintDebugSettings.defaultRightSidebarFocusHintX
    private let focusShortcutHintYOffset = ShortcutHintDebugSettings.defaultRightSidebarFocusHintY
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @AppStorage(RightSidebarBetaFeatureSettings.feedEnabledKey)
    private var feedEnabled = RightSidebarBetaFeatureSettings.defaultFeedEnabled
    @AppStorage(RightSidebarBetaFeatureSettings.dockEnabledKey)
    private var dockEnabled = RightSidebarBetaFeatureSettings.defaultDockEnabled
    @AppStorage(RightSidebarBetaFeatureSettings.artifactsEnabledKey)
    private var artifactsEnabled = RightSidebarBetaFeatureSettings.defaultArtifactsEnabled

    init(
        tabManager: TabManager,
        fileExplorerStore: FileExplorerStore,
        fileExplorerState: FileExplorerState,
        sessionIndexStore: SessionIndexStore,
        titlebarHeight: CGFloat,
        windowAppearance: WindowAppearanceSnapshot,
        workspaceId: UUID?,
        artifactWorkspace: ArtifactSidebarWorkspace?,
        artifactStore: any ArtifactStoring,
        artifactCaptureService: any ArtifactCapturing,
        onResumeSession: ((SessionEntry) -> Void)?,
        onOpenFilePreview: @escaping (String) -> Void,
        onOpenArtifact: @escaping (ArtifactSidebarRowSnapshot) -> Void,
        onOpenAsPane: @escaping (RightSidebarMode) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.tabManager = tabManager
        self.fileExplorerStore = fileExplorerStore
        self.fileExplorerState = fileExplorerState
        self.sessionIndexStore = sessionIndexStore
        self.titlebarHeight = titlebarHeight
        self.windowAppearance = windowAppearance
        self.workspaceId = workspaceId
        self.artifactWorkspace = artifactWorkspace
        self.onResumeSession = onResumeSession
        self.onOpenFilePreview = onOpenFilePreview
        self.onOpenArtifact = onOpenArtifact
        self.onOpenAsPane = onOpenAsPane
        self.onClose = onClose
        _artifactSidebarModel = State(
            initialValue: ArtifactSidebarModel(store: artifactStore, captureService: artifactCaptureService)
        )
    }

    // Re-reading the observable store inside modeBar causes SwiftUI to
    // track the pending count so the badge updates live when hooks push
    // new items.
    private var feedPendingCount: Int {
        FeedCoordinator.shared.store?.pending.count ?? 0
    }

    private var availableModes: [RightSidebarMode] {
        RightSidebarMode.availableModes(
            artifactsEnabled: artifactsEnabled,
            feedEnabled: feedEnabled,
            dockEnabled: dockEnabled
        )
    }

    private var modeBarItems: [RightSidebarModeBarItem] {
        availableModes.map { RightSidebarModeBarItem(kind: .mode($0)) }
    }

    private var focusShortcutHintAnimationValue: Bool {
        alwaysShowShortcutHints || (showModifierHoldHints && focusShortcutHintMonitor.isModifierPressed)
    }

    private func startShortcutHintMonitorsIfNeeded() {
        guard showModifierHoldHints else {
            stopShortcutHintMonitors()
            return
        }
        modeShortcutHintMonitor.start()
        focusShortcutHintMonitor.start()
        closeShortcutHintMonitor.start()
    }

    private func stopShortcutHintMonitors() {
        modeShortcutHintMonitor.stop()
        focusShortcutHintMonitor.stop()
        closeShortcutHintMonitor.stop()
    }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
                .rightSidebarChromeBottomBorder()
            contentForMode
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .shortcutHintVisibilityAnimation(value: focusShortcutHintAnimationValue)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RightSidebarKeyboardFocusBridge()
            .frame(width: 1, height: 1)
        )
        .background(
            WindowAccessor(refreshID: showModifierHoldHints) { window in
                let hintWindow = showModifierHoldHints ? window : nil
                modeShortcutHintMonitor.setHostWindow(hintWindow)
                focusShortcutHintMonitor.setHostWindow(hintWindow)
                closeShortcutHintMonitor.setHostWindow(hintWindow)
            }
            .frame(width: 0, height: 0)
        )
        .accessibilityIdentifier("RightSidebar")
        .onAppear {
            startShortcutHintMonitorsIfNeeded()
            if fileExplorerState.isVisible { hasMountedRightSidebarContent = true }
            fileExplorerState.refreshModeAvailability()
        }
        .onDisappear {
            stopShortcutHintMonitors()
        }
        .onChange(of: showModifierHoldHints) { _, _ in
            startShortcutHintMonitorsIfNeeded()
        }
        .onChange(of: fileExplorerState.isVisible) { _, visible in
            if visible { hasMountedRightSidebarContent = true }
        }
        .onChange(of: feedEnabled) { _, _ in refreshModeAvailabilityAndFocusIfNeeded() }
        .onChange(of: dockEnabled) { _, _ in refreshModeAvailabilityAndFocusIfNeeded() }
        .onChange(of: artifactsEnabled) { _, _ in refreshModeAvailabilityAndFocusIfNeeded() }
    }

    private var modeBar: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        return ZStack {
            WindowDragHandleView()

            HStack(spacing: RightSidebarChromeMetrics.headerControlSpacing) {
                ForEach(modeBarItems) { item in
                    let shortcut = item.shortcutAction.map { KeyboardShortcutSettings.shortcut(for: $0) } ?? .unbound
                    ModeBarButton(
                        item: item,
                        isSelected: item.isSelected(
                            mode: fileExplorerState.mode
                        ),
                        badgeCount: item.mode == .feed ? feedPendingCount : 0,
                        shortcutHint: shortcut,
                        showsShortcutHint: ShortcutHintTitlebarPolicy.shouldShow(
                            shortcut: shortcut,
                            alwaysShowShortcutHints: alwaysShowShortcutHints,
                            modifierPressed: modeShortcutHintMonitor.isModifierPressed,
                            modifierHoldHintsEnabled: showModifierHoldHints
                        )
                    ) {
                        let mode = item.mode
                        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                            mode: mode,
                            focusFirstItem: true,
                            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                        ) != true {
                            selectMode(mode)
                        }
                    }
                }
                Spacer(minLength: 0)
                if fileExplorerState.mode.canOpenAsPane {
                    openAsPaneButton(mode: fileExplorerState.mode)
                }
                closeButton
            }
        }
        .rightSidebarChromeBar(leadingPadding: 4, trailingPadding: 6, height: titlebarHeight)
        .overlay(alignment: .topLeading) {
            focusShortcutHintOverlay
        }
        .background(TitlebarDoubleClickMonitorView())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RightSidebarModeBar")
        .reportRightSidebarChromeGeometryForBonsplitUITest(
            isVisible: true,
            titlebarHeight: titlebarHeight
        )
    }

    private func openAsPaneButton(mode: RightSidebarMode) -> some View {
        Button {
            onOpenAsPane(mode)
        } label: {
            HeaderChromeIconStyle.symbol("rectangle.split.2x1")
        }
        .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "rightSidebarHeaderOpenAsPaneIcon"))
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
            keyPrefix: "rightSidebarHeaderOpenAsPane",
            isVisible: true
        )
        .rightSidebarHeaderControlAlignment()
        .safeHelp(String(localized: "rightSidebar.openAsPane.tooltip", defaultValue: "Open as pane"))
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "rightSidebar.openAsPane.accessibilityLabel", defaultValue: "Open %@ as Pane"),
                mode.label
            )
        )
        .accessibilityIdentifier("RightSidebar.openAsPaneButton")
        .titlebarInteractiveControl()
    }

    private var closeButton: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleRightSidebar)
        let showsShortcutHint = ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: closeShortcutHintMonitor.isModifierPressed,
            modifierHoldHintsEnabled: showModifierHoldHints
        )
        return ZStack {
            Button(action: onClose) {
                HeaderChromeIconStyle.symbol("xmark")
            }
            .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "rightSidebarHeaderCloseIcon"))
            .frame(
                width: RightSidebarChromeMetrics.headerControlSize,
                height: RightSidebarChromeMetrics.headerControlSize
            )
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                keyPrefix: "rightSidebarHeaderClose",
                isVisible: true
            )
            .safeHelp(
                KeyboardShortcutSettings.Action.toggleRightSidebar.tooltip(
                    String(localized: "rightSidebar.toggle.tooltip", defaultValue: "Toggle right sidebar")
                )
            )
            .accessibilityLabel(String(localized: "rightSidebar.close.accessibilityLabel", defaultValue: "Close Right Sidebar"))
            .accessibilityIdentifier("RightSidebar.closeButton")
        }
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .overlay(alignment: .top) {
            if showsShortcutHint {
                ShortcutHintPill(shortcut: shortcut, fontSize: 9, emphasis: 1.05)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(
                        x: CGFloat(ShortcutHintDebugSettings.clamped(closeShortcutHintXOffset)),
                        y: CGFloat(ShortcutHintDebugSettings.clamped(closeShortcutHintYOffset))
                    )
                    .shortcutHintTransition()
                    .accessibilityIdentifier("rightSidebarCloseShortcutHint")
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .rightSidebarHeaderControlAlignment()
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
        .titlebarInteractiveControl()
    }

    @ViewBuilder
    private var focusShortcutHintOverlay: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let shortcut = KeyboardShortcutSettings.shortcut(for: .focusRightSidebar)
        let showsFocusShortcutHint = ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: focusShortcutHintMonitor.isModifierPressed,
            modifierHoldHintsEnabled: showModifierHoldHints
        )
        if showsFocusShortcutHint {
            ShortcutHintPill(
                shortcut: shortcut,
                fontSize: 9,
                emphasis: 1.05
            )
                .padding(.leading, 6)
                .padding(.top, 5)
                .offset(
                    x: CGFloat(ShortcutHintDebugSettings.clamped(focusShortcutHintXOffset)),
                    y: CGFloat(ShortcutHintDebugSettings.clamped(focusShortcutHintYOffset))
                )
                .shortcutHintTransition()
                .accessibilityIdentifier("rightSidebarFocusShortcutHint")
                .allowsHitTesting(false)
                .zIndex(10)
        }
    }

    @ViewBuilder
    private var contentForMode: some View {
        if RightSidebarContentMountPolicy.shouldMountContent(isRightSidebarVisible: fileExplorerState.isVisible, hasMountedContent: hasMountedRightSidebarContent) {
            switch fileExplorerState.mode {
            case .files:
                FileExplorerPanelView(
                    store: fileExplorerStore,
                    state: fileExplorerState,
                    onOpenFilePreview: onOpenFilePreview,
                    presentation: .files
                )
            case .find:
                FileExplorerPanelView(
                    store: fileExplorerStore,
                    state: fileExplorerState,
                    onOpenFilePreview: onOpenFilePreview,
                    presentation: .find
                )
            case .sessions:
                SessionIndexView(store: sessionIndexStore, onResume: onResumeSession)
                    .onAppear {
                        sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
                    }
            case .artifacts:
                ArtifactSidebarPanelView(
                    model: artifactSidebarModel,
                    workspace: artifactWorkspace,
                    isVisible: fileExplorerState.isVisible,
                    onOpenArtifact: onOpenArtifact
                )
            case .feed:
                FeedPanelView()
            case .dock:
                dockPanel(windowAppearance: windowAppearance)
            case .customSidebar:
                EmptyView()
            }
        } else {
            Color.clear
        }
    }

    private var sessionIndexDirectory: String? {
        sessionIndexStore.currentDirectory
    }

    /// Renders this window's own Dock (created lazily on first show); no
    /// window ever defers to a Dock rendered elsewhere.
    @ViewBuilder
    private func dockPanel(windowAppearance: WindowAppearanceSnapshot) -> some View {
        if let app = AppDelegate.shared, let dock = app.windowDock(for: tabManager) {
            DockPanelView(
                store: dock,
                isSidebarVisible: fileExplorerState.isVisible,
                mode: fileExplorerState.mode,
                rootDirectory: nil,
                windowAppearance: windowAppearance,
                rightSidebarOwnsInputFocus: fileExplorerState.rightSidebarOwnsInputFocus
            )
            .id("dock.window.\(dock.workspaceId.uuidString)")
        } else {
            Color.clear
        }
    }

    private func selectMode(_ mode: RightSidebarMode) {
        fileExplorerState.mode = mode
        if fileExplorerState.mode == .sessions {
            sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
            if sessionIndexStore.entries.isEmpty {
                sessionIndexStore.reload()
            }
        }
    }

    private func refreshModeAvailabilityAndFocusIfNeeded() {
        let previousMode = fileExplorerState.mode
        fileExplorerState.refreshModeAvailability()
        let mode = fileExplorerState.mode
        // The Dock manages its own lifecycle from DockPanelView, so no dock sync
        // is needed here when the mode is unchanged.
        guard previousMode != mode,
              fileExplorerState.isVisible,
              let window = NSApp.keyWindow ?? NSApp.mainWindow
        else { return }
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: fileExplorerState.mode,
            focusFirstItem: false,
            preferredWindow: window
        )
    }
}
