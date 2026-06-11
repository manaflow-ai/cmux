import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    var updateViewModel: UpdateStateModel
    let windowId: UUID
    @Environment(TabManager.self) var tabManager
    @Environment(TerminalNotificationStore.self) var notificationStore
    @Environment(SidebarState.self) var sidebarState
    @Environment(SidebarSelectionState.self) var sidebarSelectionState
    @Environment(CmuxConfigStore.self) var cmuxConfigStore
    @Environment(FileExplorerState.self) var fileExplorerState
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("titlebarControlsStyle") private var titlebarControlsStyleRawValue = TitlebarControlsStyle.classic.rawValue
    @AppStorage(SessionPersistencePolicy.sidebarMinimumWidthKey) var sidebarMinimumWidthSetting = SessionPersistencePolicy.defaultMinimumSidebarWidth
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey) var titlebarLeftControlsLeadingInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey) var titlebarLeftControlsTopInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset
    @AppStorage(MinimalModeTitlebarDebugSettings.trafficLightTabBarInsetKey) var titlebarTrafficLightTabBarInset = MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset
    @AppStorage(MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInsetKey) var titlebarTrafficLightTitlebarLeadingInset = MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
    @State var sidebarWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarWidth)
    @State var hoveredResizerHandles: Set<SidebarResizerHandle> = []
    @State var isResizerDragging = false
    @State var sidebarDragStartWidth: CGFloat?
    @State var selectedTabIds: Set<UUID> = []
    @State var mountedWorkspaceIds: [UUID] = []
    @State var lastSidebarSelectionIndex: Int? = nil
    @State var titlebarText: String = ""
    @State var isFullScreen: Bool = false
    @State var observedWindow: NSWindow?
    @State var fullscreenControlsViewModel = TitlebarControlsViewModel()
    @State var fileExplorerStore = FileExplorerStore()
    @State var sessionIndexStore = SessionIndexStore()
    @State private var selectedWorkspaceDirectoryObserver = SelectedWorkspaceDirectoryObserver()
    @State var commandPaletteOverlayRenderModel = CommandPaletteOverlayRenderModel()
    @State private var backgroundWorkspacePrimeCoordinator = BackgroundWorkspacePrimeCoordinator()
    @State var fileExplorerWidth: CGFloat = 220
    @State var fileExplorerDragStartWidth: CGFloat?
    @State var previousSelectedWorkspaceId: UUID?
    @State var retiringWorkspaceId: UUID?
    @State var workspaceHandoffGeneration: UInt64 = 0
    @State var workspaceHandoffFallbackTask: Task<Void, Never>?
    @State var didApplyUITestSidebarSelection = false
    @State var titlebarThemeGeneration: UInt64 = 0
    @State var sidebarDraggedTabId: UUID?
    @State var titlebarTextUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    @State var sidebarResizerCursorReleaseWorkItem: DispatchWorkItem?
    @State var sidebarResizerPointerMonitor: Any?
    @State var isResizerBandActive = false
    @State var isSidebarResizerCursorActive = false
    @State var sidebarResizerCursorStabilizer: DispatchSourceTimer?
    @State var isCommandPalettePresented = false
    @State var commandPaletteQuery: String = ""
    @State var commandPaletteMode: CommandPaletteMode = .commands
    @State var commandPaletteRenameDraft: String = ""
    @State var commandPaletteWorkspaceDescriptionDraft: String = ""
    @State var commandPaletteWorkspaceDescriptionHeight: CGFloat = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
    @State var commandPaletteSelectedResultIndex: Int = 0
    @State var commandPaletteSelectionAnchorCommandID: String?
    @State var commandPaletteScrollTargetIndex: Int?
    @State var commandPaletteScrollTargetAnchor: UnitPoint?
    @State var commandPaletteRestoreFocusTarget: CommandPaletteRestoreFocusTarget?
    @State var commandPaletteSearchCorpus: [CommandPaletteSearchCorpusEntry<String>] = []
    @State var commandPaletteSearchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>] = [:]
    @State var commandPaletteSearchCommandsByID: [String: CommandPaletteCommand] = [:]
    @State var commandPaletteNucleoSearchIndex: CommandPaletteNucleoSearchIndex<String>?
    @State var commandPaletteSearchIndexBuildTask: Task<Void, Never>?
    @State var commandPaletteSearchIndexBuildGeneration: UInt64 = 0
    @State var cachedCommandPaletteResults: [CommandPaletteSearchResult] = []
    @State var commandPaletteVisibleResults: [CommandPaletteSearchResult] = []
    @State var commandPaletteVisibleResultsVersion: UInt64 = 0
    @State var commandPaletteVisibleResultsScope: CommandPaletteListScope?
    @State var commandPaletteVisibleResultsFingerprint: Int?
    @State var cachedCommandPaletteScope: CommandPaletteListScope?
    @State var cachedCommandPaletteFingerprint: Int?
    @State var cachedDefaultTerminalIsDefault = DefaultTerminalRegistration.currentStatus().isDefault
    @State var commandPalettePendingDismissFocusTarget: CommandPaletteRestoreFocusTarget?
    @State var commandPaletteRestoreTimeoutWorkItem: DispatchWorkItem?
    @State var commandPalettePendingTextSelectionBehavior: CommandPaletteTextSelectionBehavior?
    @State var commandPaletteSearchTask: Task<Void, Never>?
    @State var commandPaletteSearchRequestID: UInt64 = 0
    @State var commandPaletteResolvedSearchRequestID: UInt64 = 0
    @State var commandPaletteResolvedSearchScope: CommandPaletteListScope?
    @State var commandPaletteResolvedSearchFingerprint: Int?
    @State var commandPaletteResolvedMatchingQuery = ""
    @State var commandPaletteTerminalOpenTargetAvailability: Set<TerminalDirectoryOpenTarget> = []
    @State var commandPaletteForkableAgentActivePanelKey: String?
    @State var commandPaletteForkableAgentProbeIDsByPanelKey: [String: UUID] = [:]
    @State var commandPaletteForkableAgentSupportedPanelKeys: Set<String> = []
    @State var commandPaletteForkableAgentSnapshotsByPanelKey: [String: SessionRestorableAgentSnapshot] = [:]
    @State var commandPaletteForkableAgentSnapshotFingerprintsByPanelKey: [String: String] = [:]
    @State var commandPaletteForkableAgentRemoteContextsByPanelKey: [String: Bool] = [:]
    @State var commandPaletteForkableAgentResultHadFallbackByPanelKey: [String: Bool] = [:]
    @State var commandPaletteForkableAgentAvailabilityTasksByPanelKey: [String: Task<Void, Never>] = [:]
    @State var commandPaletteForkableAgentProbeFingerprintsByPanelKey: [String: String] = [:]
    @State var isCommandPaletteSearchPending = false
    @State var commandPalettePendingActivation: CommandPalettePendingActivation?
    @State var commandPaletteResultsRevision: UInt64 = 0
    @State var commandPaletteUsageHistoryByCommandId: [String: CommandPaletteUsageEntry] = [:]
    @State var isFeedbackComposerPresented = false
    @AppStorage(CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
    private var commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
    @AppStorage(CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey)
    var commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
    @AppStorage(AppearanceSettings.appearanceModeKey) var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @State var commandPaletteShouldFocusWorkspaceDescriptionEditor = false
    @FocusState var isCommandPaletteSearchFocused: Bool
    @FocusState var isCommandPaletteRenameFocused: Bool

    /// Native titlebar inset reported by AppKit. Standard mode follows cmux's visual chrome;
    /// minimal WindowGroup hosts can still need the reported safe area cancelled.
    @State var titlebarPadding: CGFloat = WindowChromeMetrics.defaultTitlebarHeight
    /// SwiftUI WindowGroup windows can still report a titlebar safe area; manually created
    /// main windows use MainWindowHostingView and report zero.
    @State var hostingSafeAreaTop: CGFloat = 0
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    @AppStorage("sidebarBlendMode") var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarMatchTerminalBackground") var sidebarMatchTerminalBackground = false
    @AppStorage("sidebarTintOpacity") var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage("sidebarTintHex") var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") var sidebarTintHexDark: String?
    @AppStorage("sidebarMaterial") var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarState") var sidebarStateSetting = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") var sidebarBlurOpacity = 1.0

    // Background glass settings
    @AppStorage("bgGlassTintHex") var bgGlassTintHex = "#000000"
    @AppStorage("bgGlassTintOpacity") var bgGlassTintOpacity = 0.03
    @AppStorage("bgGlassEnabled") var bgGlassEnabled = false
    @State var titlebarLeadingInset: CGFloat = 12
    var body: some View {
        let appearance = windowAppearanceSnapshot
        var view = AnyView(
            ZStack(alignment: .topLeading) {
                WindowBackdropLayer(role: .windowRoot, snapshot: appearance)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                contentAndSidebarLayout(appearance: appearance)

                if !isMinimalMode {
                    workspaceTitlebarBand(appearance: appearance)
                        .zIndex(100)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(minWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth), minHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight))
                .background(Color.clear)
                .background(
                    MinimalModeTitlebarEventSurfaceView(isEnabled: isMinimalMode && !isFullScreen)
                )
        )

        view = AnyView(view.onAppear {
            selectedWorkspaceDirectoryObserver.wire(tabManager: tabManager)
            tabManager.applyWindowBackgroundForSelectedTab()
            reconcileMountedWorkspaceIds()
            previousSelectedWorkspaceId = tabManager.selectedTabId
            installSidebarResizerPointerMonitorIfNeeded()
            let restoredWidth = normalizedSidebarWidth(sidebarState.persistedWidth)
            if abs(sidebarWidth - restoredWidth) > 0.5 {
                sidebarWidth = restoredWidth
            }
            if abs(sidebarState.persistedWidth - restoredWidth) > 0.5 {
                sidebarState.persistedWidth = restoredWidth
            }
            if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                selectedTabIds = [selectedId]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
            }
            syncSidebarSelectedWorkspaceIds()
            applyUITestSidebarSelectionIfNeeded(tabs: tabManager.tabs)
            updateTitlebarText()
            syncTrafficLightInset()

            // Startup recovery (#399): if session restore or a race condition leaves the
            // view in a broken state (empty tabs, no selection, unmounted workspaces),
            // detect and recover after a short delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak tabManager] in
                guard let tabManager else { return }
                var didRecover = false

                // Ensure there is at least one workspace.
                if tabManager.tabs.isEmpty {
                    tabManager.addWorkspace()
                    didRecover = true
                }

                // Ensure selectedTabId points to an existing workspace.
                if tabManager.selectedTabId == nil || !tabManager.tabs.contains(where: { $0.id == tabManager.selectedTabId }) {
                    tabManager.selectedTabId = tabManager.tabs.first?.id
                    didRecover = true
                }

                // Ensure mountedWorkspaceIds is populated.
                if mountedWorkspaceIds.isEmpty || !mountedWorkspaceIds.contains(where: { id in tabManager.tabs.contains { $0.id == id } }) {
                    reconcileMountedWorkspaceIds()
                    didRecover = true
                }

                // Ensure sidebar selection is valid.
                if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                    didRecover = true
                }

                syncSidebarSelectedWorkspaceIds()
                applyUITestSidebarSelectionIfNeeded(tabs: tabManager.tabs)

                if didRecover {
#if DEBUG
                    cmuxDebugLog("startup.recovery tabCount=\(tabManager.tabs.count) selected=\(tabManager.selectedTabId?.uuidString.prefix(8) ?? "nil") mounted=\(mountedWorkspaceIds.count)")
#endif
                    sentryBreadcrumb("startup.recovery", data: [
                        "tabCount": tabManager.tabs.count,
                        "selectedTabId": tabManager.selectedTabId?.uuidString ?? "nil",
                        "mountedCount": mountedWorkspaceIds.count
                    ])
                }
            }
        })

        view = AnyView(view.onChange(of: tabManager.selectedTabId) { newValue in
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.view.selectedChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) selected=\(debugShortWorkspaceId(newValue))"
                )
            } else {
                cmuxDebugLog("ws.view.selectedChange id=none selected=\(debugShortWorkspaceId(newValue))")
            }
#endif
            tabManager.applyWindowBackgroundForSelectedTab()
            startWorkspaceHandoffIfNeeded(newSelectedId: newValue)
            reconcileMountedWorkspaceIds(selectedId: newValue)
            AppDelegate.shared?.syncBonsplitTabShortcutHintEligibility(in: observedWindow)
            guard let newValue else { return }
            if selectedTabIds.count <= 1 {
                selectedTabIds = [newValue]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == newValue }
            }
            updateTitlebarText()
        })

        view = AnyView(view.onChange(of: selectedTabIds) { _ in
            syncSidebarSelectedWorkspaceIds()
        })

        // File explorer: keep the Combine subscription stable across body re-evaluations.
        view = AnyView(view.onChange(of: selectedWorkspaceDirectoryObserver.directoryChangeGeneration) { _ in
            syncFileExplorerDirectory()
        })

        view = AnyView(view.onChange(of: tabManager.isWorkspaceCycleHot) { _ in
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.view.hotChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)"
                )
            } else {
                cmuxDebugLog("ws.view.hotChange id=none hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)")
            }
#endif
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onChange(of: retiringWorkspaceId) { _ in
            reconcileMountedWorkspaceIds()
        })

        // Prime background workspaces off-screen. Rendering them just to run a task
        // mounts every keepAllAlive tab view and can materialize hidden terminals.
        view = AnyView(view.task(id: backgroundWorkspacePrimeCoordinator.taskKey(for: tabManager)) {
            await backgroundWorkspacePrimeCoordinator.primePendingBackgroundWorkspaces(tabManager: tabManager)
        })

        view = AnyView(view.onReceive(tabManager.debugPinnedWorkspaceLoadIdsPublisher) { _ in
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onReceive(tabManager.mountedBackgroundWorkspaceLoadIdsPublisher) { _ in
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidSetTitle)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { notification in
            let payloadHex = (notification.userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString()
            let eventId = (notification.userInfo?[GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value
            let source = notification.userInfo?[GhosttyNotificationKey.backgroundSource] as? String
            scheduleTitlebarThemeRefresh(
                reason: "ghosttyDefaultBackgroundDidChange",
                backgroundEventId: eventId,
                backgroundSource: source,
                notificationPayloadHex: payloadHex
            )
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusTab)) { _ in
            sidebarSelectionState.selection = .tabs
            scheduleTitlebarTextRefresh()
        })

        // A grouped anchor's title-bar name is derived from its group's name, so
        // a group rename must refresh the cached titlebar text (#5404). Scope to
        // this view's `tabManager` (the notification's `object`) so a rename in
        // another window doesn't spuriously refresh this one.
        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .workspaceGroupNameDidChange, object: tabManager)) { _ in
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusSurface)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: tabId, reason: "focus")
            attemptCommandPaletteFocusRestoreIfNeeded()
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onChange(of: titlebarThemeGeneration) { oldValue, newValue in
            guard GhosttyApp.shared.backgroundLogEnabled else { return }
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh applied oldGeneration=\(oldValue) generation=\(newValue) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidBecomeFirstResponderSurface)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: tabId, reason: "first_responder")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidBecomeFirstResponderWebView)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  let focusedPanelId = selectedWorkspace.focusedPanelId,
                  let focusedBrowser = selectedWorkspace.browserPanel(for: focusedPanelId),
                  focusedBrowser.webView === webView else { return }
            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                workspaceId: selectedTabId,
                panelId: focusedPanelId,
                in: observedWindow ?? webView.window
            )
            completeWorkspaceHandoffIfNeeded(focusedTabId: selectedTabId, reason: "browser_first_responder")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .webViewDidReceiveClick)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  let focusedBrowser = selectedWorkspace.panels.values.compactMap({ $0 as? BrowserPanel })
                    .first(where: { $0.webView === webView }) else { return }
            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                workspaceId: selectedTabId,
                panelId: focusedBrowser.id,
                in: observedWindow ?? webView.window
            )
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidFocusAddressBar)) { notification in
            guard let panelId = notification.object as? UUID,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  selectedWorkspace.focusedPanelId == panelId,
                  let focusedBrowser = selectedWorkspace.browserPanel(for: panelId) else { return }
            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                workspaceId: selectedTabId,
                panelId: panelId,
                in: observedWindow ?? focusedBrowser.webView.window
            )
            completeWorkspaceHandoffIfNeeded(focusedTabId: selectedTabId, reason: "browser_address_bar")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification,
            object: observedWindow
        )) { _ in
            attemptCommandPaletteFocusRestoreIfNeeded()
            attemptCommandPaletteTextSelectionIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification)) { notification in
            guard commandPalettePendingTextSelectionBehavior != nil else { return }
            guard let editor = notification.object as? NSTextView,
                  editor.isFieldEditor else { return }
            guard let observedWindow else { return }
            guard editor.window === observedWindow else { return }
            attemptCommandPaletteTextSelectionIfNeeded()
        })

        view = AnyView(view.onChange(of: isCommandPaletteSearchFocused) { _, focused in
            if focused {
                attemptCommandPaletteTextSelectionIfNeeded()
            }
        })

        view = AnyView(view.onChange(of: isCommandPaletteRenameFocused) { _, focused in
            if focused {
                attemptCommandPaletteTextSelectionIfNeeded()
            }
        })

        view = AnyView(view.onReceive(tabManager.tabsPublisher) { tabs in
            let existingIds = Set(tabs.map { $0.id })
            if let retiringWorkspaceId, !existingIds.contains(retiringWorkspaceId) {
                self.retiringWorkspaceId = nil
                workspaceHandoffFallbackTask?.cancel()
                workspaceHandoffFallbackTask = nil
            }
            if let previousSelectedWorkspaceId, !existingIds.contains(previousSelectedWorkspaceId) {
                self.previousSelectedWorkspaceId = tabManager.selectedTabId
            }
            tabManager.pruneBackgroundWorkspaceLoads(existingIds: existingIds)
            reconcileMountedWorkspaceIds(tabs: tabs)
            selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
            if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                selectedTabIds = [selectedId]
            }
            if let lastIndex = lastSidebarSelectionIndex, lastIndex >= tabs.count {
                if let selectedId = tabManager.selectedTabId {
                    lastSidebarSelectionIndex = tabs.firstIndex { $0.id == selectedId }
                } else {
                    lastSidebarSelectionIndex = nil
                }
            }
            syncSidebarSelectedWorkspaceIds()
            applyUITestSidebarSelectionIfNeeded(tabs: tabs)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.stateDidChange)) { notification in
            let tabId = SidebarDragLifecycleNotification.tabId(from: notification)
            sidebarDraggedTabId = tabId
#if DEBUG
            cmuxDebugLog(
                "sidebar.dragState.content tab=\(debugShortWorkspaceId(tabId)) " +
                "reason=\(SidebarDragLifecycleNotification.reason(from: notification))"
            )
#endif
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteToggleRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            toggleCommandPalette()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteCommands()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteSwitcherRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteSwitcher()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .defaultTerminalRegistrationDidChange)) { _ in
            refreshCachedDefaultTerminalStatus()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteSubmitRequested)) { notification in
            guard isCommandPalettePresented else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            handleCommandPaletteSubmitRequest()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteDismissRequested)) { notification in
            guard isCommandPalettePresented else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            dismissCommandPalette()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameTabRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteRenameTabInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameWorkspaceRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteRenameWorkspaceInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteEditWorkspaceDescriptionRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            let shouldHandle = Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            )
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.request observed={\(debugCommandPaletteWindowSummary(observedWindow))} " +
                "requested={\(debugCommandPaletteWindowSummary(requestedWindow))} " +
                "shouldHandle=\(shouldHandle ? 1 : 0) presented=\(isCommandPalettePresented ? 1 : 0) " +
                "mode=\(debugCommandPaletteModeLabel(commandPaletteMode))"
            )
#endif
            guard shouldHandle else { return }
            openCommandPaletteWorkspaceDescriptionInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteMoveSelection)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .commands = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            guard let delta = notification.userInfo?["delta"] as? Int, delta != 0 else { return }
            moveCommandPaletteSelection(by: delta)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputInteractionRequested)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .renameInput = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            handleCommandPaletteRenameInputInteraction()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputDeleteBackwardRequested)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .renameInput = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            _ = handleCommandPaletteRenameDeleteBackward(modifiers: [])
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .feedbackComposerRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            presentFeedbackComposer()
        })

        view = AnyView(view.background(WindowAccessor(dedupeByWindow: false) { window in
            let tmuxOverlayState = tmuxWorkspacePaneWindowOverlayState(for: window)
            tmuxWorkspacePaneWindowOverlayController(for: window, createIfNeeded: tmuxOverlayState != nil)?.update(state: tmuxOverlayState)
            let overlayController = commandPaletteWindowOverlayController(for: window)
            overlayController.update(isVisible: isCommandPalettePresented) { AnyView(commandPaletteOverlay) }
        }))

        view = AnyView(view.onChange(of: bgGlassTintHex) { _ in
            updateWindowGlassTint()
        })

        view = AnyView(view.onChange(of: bgGlassTintOpacity) { _ in
            updateWindowGlassTint()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = true
            setTitlebarControlsHidden(true, in: window)
            AppDelegate.shared?.fullscreenControlsViewModel = fullscreenControlsViewModel
            syncTrafficLightInset()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = false
            setTitlebarControlsHidden(false, in: window)
            AppDelegate.shared?.fullscreenControlsViewModel = nil
            syncTrafficLightInset()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            let availableWidth = window.contentView?.bounds.width ?? window.contentLayoutRect.width
            clampSidebarWidthIfNeeded(availableWidth: availableWidth)
            clampRightSidebarWidthIfNeeded(availableWidth: availableWidth)
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarWidth) { _ in
            let sanitized = normalizedSidebarWidth(sidebarWidth)
            if abs(sidebarWidth - sanitized) > 0.5 {
                sidebarWidth = sanitized
                return
            }
            if abs(sidebarState.persistedWidth - sanitized) > 0.5 {
                sidebarState.persistedWidth = sanitized
            }
            // Sidebar width changes are pure SwiftUI layout updates, so portal-hosted
            // terminals and browsers need an explicit post-layout geometry resync.
            schedulePortalGeometrySynchronize()
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarMinimumWidthSetting) { _ in
            clampSidebarWidthIfNeeded()
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: titlebarControlsStyleRawValue) { _ in
            clampSidebarWidthIfNeeded()
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarState.isVisible) { _, isVisible in
            setMinimalModeSidebarTitlebarControlsAvailable(isVisible, in: observedWindow)
            if let observedWindow {
                AppDelegate.shared?.applyWindowDecorations(to: observedWindow)
            }
            schedulePortalGeometrySynchronize()
            updateSidebarResizerBandState()
            syncTrafficLightInset()
        })

        view = AnyView(view.onChange(of: fileExplorerState.isVisible) { isVisible in
            if !isVisible {
                _ = AppDelegate.shared?.restoreTerminalFocusAfterRightSidebarHidden(in: observedWindow)
            }
            syncFileExplorerDirectory()
            if let observedWindow {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
            } else {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
            }
        })

        view = AnyView(view.onChange(of: fileExplorerState.mode) { _, _ in
            syncFileExplorerDirectory()
        })

        view = AnyView(view.onChange(of: sidebarMatchTerminalBackground) { _ in
            tabManager.applyWindowBackdropModeForAllTabs(reason: "sidebarMatchTerminalBackgroundChanged")
            guard sidebarState.isVisible,
                  sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue else { return }
            schedulePortalGeometrySynchronize()
        })

        view = AnyView(view.onChange(of: isMinimalMode) { _, _ in
            if let observedWindow {
                setTitlebarControlsHidden(isFullScreen, in: observedWindow)
                AppDelegate.shared?.applyWindowDecorations(to: observedWindow)
                refreshWindowChromeMetrics(for: observedWindow)
                observedWindow.contentView?.needsLayout = true
                observedWindow.contentView?.superview?.needsLayout = true
                observedWindow.invalidateShadow()
            }
            schedulePortalGeometrySynchronize()
            updateSidebarResizerBandState()
            syncTrafficLightInset()
        })

        view = AnyView(view.onChange(of: titlebarDebugChromeSnapshot) { _, _ in
            applyTitlebarDebugChromeChange()
        })

        view = AnyView(view.onChange(of: tabManager.tabs.map(\.id)) { _ in
            syncTrafficLightInset()
        })

        view = AnyView(view.onChange(of: sidebarState.persistedWidth) { newValue in
            let sanitized = normalizedSidebarWidth(newValue)
            if abs(newValue - sanitized) > 0.5 {
                sidebarState.persistedWidth = sanitized
                return
            }
            guard !isResizerDragging else { return }
            if abs(sidebarWidth - sanitized) > 0.5 {
                sidebarWidth = sanitized
            }
        })

        view = AnyView(view.ignoresSafeArea())
        view = AnyView(view.sheet(isPresented: $isFeedbackComposerPresented) {
            SidebarFeedbackComposerSheet()
        })

        view = AnyView(view.onDisappear {
            if isResizerDragging {
                TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                isResizerDragging = false
                sidebarDragStartWidth = nil
            }
            removeSidebarResizerPointerMonitor()
        })

        view = AnyView(view.background(WindowAccessor(refreshID: appearance.appKitWindowMutationID) { [appearance] window in
            window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
            window.isRestorable = false
            setMinimalModeSidebarTitlebarControlsAvailable(sidebarState.isVisible, in: window)
            window.titlebarAppearsTransparent = true
            // Native AppKit titlebar dragging steals pane-tab drags in minimal
            // mode. Keep the main window immovable by default; explicit chrome
            // drag zones temporarily enable performDrag for real app moves.
            configureCmuxMainWindowDragBehavior(window)
            window.styleMask.insert(.fullSizeContentView)

            // Track this window for fullscreen notifications
            if observedWindow !== window {
                DispatchQueue.main.async {
                    observedWindow = window
                    isFullScreen = window.styleMask.contains(.fullScreen)
                    let availableWidth = window.contentView?.bounds.width ?? window.contentLayoutRect.width
                    clampSidebarWidthIfNeeded(availableWidth: availableWidth)
                    clampRightSidebarWidthIfNeeded(availableWidth: availableWidth)
                    syncCommandPaletteDebugStateForObservedWindow()
                    installSidebarResizerPointerMonitorIfNeeded()
                    updateSidebarResizerBandState()
                }
            }

            refreshWindowChromeMetrics(for: window)
            // Keep content below the titlebar so drags on Bonsplit's tab bar don't
            // get interpreted as window drags.
            // User settings decide whether window glass is active. The native Tahoe
            // NSGlassEffectView path vs the older NSVisualEffectView fallback is chosen
            // inside WindowGlassEffect.apply.
            let backdropPlan = appearance.backdropPlan()
            removeNativeTitlebarBackdrop(in: window)
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1" {
                AppDelegate.shared?.updateLog.append("ui test window accessor: id=\(windowIdentifier) visible=\(window.isVisible)")
            }
#endif
            let backdropResult = WindowBackdropController.apply(plan: backdropPlan, to: window)
            if backdropResult.didChangeGlassRoot {
                let tmuxOverlayState = tmuxWorkspacePaneWindowOverlayState(for: window)
                tmuxWorkspacePaneWindowOverlayController(for: window, createIfNeeded: tmuxOverlayState != nil)?.update(state: tmuxOverlayState)
                commandPaletteWindowOverlayController(for: window)
                    .update(isVisible: isCommandPalettePresented) { AnyView(commandPaletteOverlay) }
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
                BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
            }
            AppDelegate.shared?.attachUpdateAccessory(to: window)
            AppDelegate.shared?.applyWindowDecorations(to: window)
            // Let cmux supply the translucent titlebar fills. AppKit's native
            // material otherwise blends a lighter strip over the terminal area.
            syncNativeTitlebarBackdrop(
                in: window,
                enabled: true,
                usesGlassStyle: backdropResult.usesWindowGlass
            )
            AppDelegate.shared?.registerMainWindow(
                window,
                windowId: windowId,
                tabManager: tabManager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState,
                fileExplorerState: fileExplorerState,
                cmuxConfigStore: cmuxConfigStore
            )
            installFileDropOverlayWhenReady(on: window, tabManager: tabManager)
        }))

        return AnyView(view.cmuxAppearanceColorScheme(appearanceMode))
    }

}

