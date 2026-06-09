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

struct VerticalTabsSidebar: View {
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let windowId: UUID
    let onSendFeedback: () -> Void
    let onToggleSidebar: () -> Void
    let onNewTab: () -> Void
    let observedWindow: NSWindow?
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var cmuxConfigStore: CmuxConfigStore
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @State var modifierKeyMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @StateObject var dragAutoScrollController = SidebarDragAutoScrollController()
    @StateObject private var dragFailsafeMonitor = SidebarDragFailsafeMonitor()
    @StateObject private var tabItemSettingsStore = SidebarTabItemSettingsStore(
        initialSidebarFontSize: GhosttyConfig.load().sidebarFontSize
    )
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State var dragState = SidebarDragState()
    // Bonsplit tab drags arrive through AppKit pasteboard callbacks, not
    // `SidebarDragState`, so they need a separate transient collection flag.
    @State private var isBonsplitWorkspaceDropTargetCollectionActive = false
    @State private var bonsplitWorkspaceDropTargetBridge = SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge()
    // Freezes `showsModifierShortcutHints` for the workspace whose context menu
    // is open. Set on the row's contextMenu.onAppear and cleared on
    // .onDisappear so modifier-key transitions don't flip the badges on the
    // row sitting behind the open menu. See `SidebarShortcutHintFreezePolicy`.
    @State private var frozenShortcutHintsTabId: UUID?
    @State private var frozenShortcutHintsValue: Bool = false
    @State private var laidOutWorkspaceRowIds: Set<UUID> = []
    @State private var pendingSelectedWorkspaceScrollId: UUID?
    @State private var collapsedExtensionSidebarSectionIds: Set<String> = []
    @State private var extensionSidebarWorktreeCreationInFlightSectionIds: Set<String> = []
    @State private var extensionSidebarUpdateToken: UInt64 = 0
    /// Bumped whenever any workspace's currentDirectory changes; the group
    /// header's resolved cwd-based config (color/icon/context menu /
    /// newWorkspacePlacement) reads it through the body, so a state
    /// invalidation here forces SwiftUI to re-call
    /// `cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd:)`. The anchor
    /// has no TabItemView, so no implicit per-row publisher subscription
    /// would otherwise fire on `cd` while it's not selected.
    @State private var anchorCwdRevision: Int = 0
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(CmuxExtensionSidebarSelection.defaultsKey)
    private var selectedExtensionSidebarProviderId = CmuxExtensionSidebarSelection.defaultProviderId
    @LiveSetting(\.betaFeatures.extensions) private var extensionsExperimentalEnabled
    @LiveSetting(\.betaFeatures.customSidebars) private var customSidebarsExperimentalEnabled

    // The provider to actually render. Built-in views are always honored; only
    // the hosted-extension selection falls back to the default workspaces
    // sidebar while the experimental Extensions feature is disabled, since
    // turning extensions off hides that entry and would otherwise strand the
    // user with no way back. Deriving the effective provider (rather than
    // mutating the persisted selection via an observer) routes correctly on the
    // first render pass and restores the user's choice if extensions are
    // re-enabled. Reading `extensionsExperimentalEnabled` here keeps the view
    // reactive to the flag toggling.
    private var effectiveExtensionSidebarProviderId: String {
        let selected = selectedExtensionSidebarProviderId
        if selected.hasPrefix(CmuxExtensionSidebarSelection.customSidebarProviderPrefix) {
            // Touch the @LiveSetting so toggling the flag in Settings still
            // re-renders, but decide with the synchronous UserDefaults read:
            // on a sidebar remount @LiveSetting's initial value lags one tick,
            // which would otherwise flash the default sidebar for a frame
            // before swapping to the custom one.
            _ = customSidebarsExperimentalEnabled
            return CmuxExtensionSidebarSelection.customSidebarsEnabled
                ? selected
                : CmuxExtensionSidebarSelection.defaultProviderId
        }
        return CmuxExtensionSidebarSelection.effectiveProviderId(
            selectedExtensionSidebarProviderId,
            extensionsEnabled: extensionsExperimentalEnabled
        )
    }

    /// Live, read-only projection of workspace state handed to custom
    /// sidebars so interpreted Swift can bind to it (e.g.
    /// `ForEach(workspaces) { w in Text(w.title) }`) and re-render when it
    /// changes. A value snapshot built fresh each render, never the store
    /// itself, so it respects the sidebar snapshot-boundary rule.
    private func customSidebarDataContext(now: Date) -> [String: SwiftValue] {
        let selectedId = tabManager.selectedTabId
        let workspaces: [SwiftValue] = tabManager.tabs.enumerated().map { index, workspace in
            customSidebarWorkspaceValue(workspace, index: index, selectedId: selectedId)
        }
        let selectedWorkspace = tabManager.tabs.first { $0.id == selectedId }
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .weekday], from: now)
        let hour = c.hour ?? 0, minute = c.minute ?? 0, second = c.second ?? 0
        let clock: SwiftValue = .object([
            "time": .string(String(format: "%02d:%02d:%02d", hour, minute, second)),
            "hour": .int(hour),
            "minute": .int(minute),
            "second": .int(second),
            "weekday": .int(c.weekday ?? 0),
            "epoch": .int(Int(now.timeIntervalSince1970)),
        ])
        return [
            "workspaces": .array(workspaces),
            "workspaceCount": .int(tabManager.tabs.count),
            "selectedTitle": .string(selectedWorkspace?.customTitle ?? selectedWorkspace?.title ?? ""),
            "selectedId": .string(selectedId?.uuidString ?? ""),
            "unreadTotal": .int(notificationStore.unreadCount),
            "clock": clock,
        ]
    }

    /// Projects one workspace's live state into the interpreter value tree.
    /// Optional fields are omitted when absent so interpreted `if let` / ternary
    /// truthiness behaves; always-present fields default sensibly. Keep this in
    /// sync with the data keys documented in `docs/custom-sidebars.md`.
    private func customSidebarWorkspaceValue(_ workspace: Workspace, index: Int, selectedId: UUID?) -> SwiftValue {
        let focusedPanelId = workspace.focusedPanelId
        var fields: [String: SwiftValue] = [
            "id": .string(workspace.id.uuidString),
            "title": .string(workspace.customTitle ?? workspace.title),
            "selected": .bool(workspace.id == selectedId),
            "pinned": .bool(workspace.isPinned),
            "index": .int(index),
            "directory": .string(workspace.currentDirectory),
            "ports": .array(workspace.listeningPorts.map { .int($0) }),
            "portCount": .int(workspace.listeningPorts.count),
            "unread": .int(notificationStore.unreadCount(forTabId: workspace.id)),
            "tabs": .array(customSidebarSurfaceValues(workspace, focusedPanelId: focusedPanelId)),
            "tabCount": .int(workspace.bonsplitController.allPaneIds.reduce(0) { $0 + workspace.bonsplitController.tabs(inPane: $1).count }),
        ]
        if let description = workspace.customDescription, !description.isEmpty { fields["description"] = .string(description) }
        if let color = workspace.customColor, !color.isEmpty { fields["color"] = .string(color) }
        if let git = workspace.gitBranch {
            fields["branch"] = .string(git.branch)
            fields["dirty"] = .bool(git.isDirty)
        }
        if let pr = workspace.pullRequest {
            var prFields: [String: SwiftValue] = [
                "number": .int(pr.number),
                "label": .string(pr.label),
                "url": .string(pr.url.absoluteString),
                "status": .string(pr.status.rawValue),
                "stale": .bool(pr.isStale),
            ]
            if let prBranch = pr.branch { prFields["branch"] = .string(prBranch) }
            fields["pr"] = .object(prFields)
        }
        if let progress = workspace.progress {
            var progressFields: [String: SwiftValue] = ["value": .double(progress.value)]
            if let label = progress.label { progressFields["label"] = .string(label) }
            fields["progress"] = .object(progressFields)
        }
        if let message = workspace.latestConversationMessage, !message.isEmpty { fields["latestMessage"] = .string(message) }
        if let prompt = workspace.latestSubmittedMessage, !prompt.isEmpty { fields["latestPrompt"] = .string(prompt) }
        if let at = workspace.latestSubmittedAt { fields["latestAt"] = .int(Int(at.timeIntervalSince1970)) }
        if let target = workspace.remoteDisplayTarget {
            fields["remote"] = .object([
                "target": .string(target),
                "state": .string(workspace.remoteConnectionState.rawValue),
                "connected": .bool(workspace.remoteConnectionState == .connected),
            ])
        }
        return .object(fields)
    }

    /// Projects a workspace's surfaces (terminal/browser/etc. tabs) into the
    /// interpreter value tree, enriched with per-surface directory, pin, git,
    /// and ports where available.
    private func customSidebarSurfaceValues(_ workspace: Workspace, focusedPanelId: UUID?) -> [SwiftValue] {
        var tabs: [SwiftValue] = []
        for paneId in workspace.bonsplitController.allPaneIds {
            for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                var surfaceFields: [String: SwiftValue] = [
                    "id": .string(panelId.uuidString),
                    "title": .string(tab.title),
                    "focused": .bool(panelId == focusedPanelId),
                    "pinned": .bool(workspace.pinnedPanelIds.contains(panelId)),
                ]
                if let directory = workspace.panelDirectories[panelId], !directory.isEmpty {
                    surfaceFields["directory"] = .string(directory)
                }
                if let git = workspace.panelGitBranches[panelId] {
                    surfaceFields["branch"] = .string(git.branch)
                    surfaceFields["dirty"] = .bool(git.isDirty)
                }
                if let ports = workspace.surfaceListeningPorts[panelId], !ports.isEmpty {
                    surfaceFields["ports"] = .array(ports.map { .int($0) })
                }
                tabs.append(.object(surfaceFields))
            }
        }
        return tabs
    }
    @AppStorage("sidebarMatchTerminalBackground")
    private var sidebarMatchTerminalBackground = false
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
    private var titlebarLeftControlsLeadingInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey)
    private var titlebarLeftControlsTopInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset

    let tabRowSpacing: CGFloat = 2
    private static let extensionSidebarObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(40)
    private static let extensionSidebarDisclosureAnimation = Animation.easeInOut(duration: 0.18)
    private var sidebarTitlebarInteractionHeight: CGFloat {
        MinimalModeChromeMetrics.titlebarHeight
    }

    /// Adapter binding for unmigrated consumers (extension sidebar drop
    /// delegates, bonsplit overlays) that still expect @Binding<UUID?>. Reads
    /// flow through `dragState.draggedTabId` so @Observable per-property
    /// tracking still applies to whoever calls the binding's get.
    private var draggedTabIdBinding: Binding<UUID?> {
        Binding(
            get: { dragState.draggedTabId },
            // Route the clear through `clearDrag()` so a locally originated drag
            // also ends its `SidebarWorkspaceDragRegistry` entry. The extension /
            // browser-stack sidebar drop delegates end drags by writing `nil`
            // through this binding; without this they'd leave the process-wide
            // registry stale and a later cross-window drop could act on it.
            set: { newValue in
                if let newValue {
                    dragState.draggedTabId = newValue
                } else {
                    dragState.clearDrag()
                }
            }
        )
    }

    /// Adapter binding mirroring `draggedTabIdBinding`. See its doc comment.
    private var dropIndicatorBinding: Binding<SidebarDropIndicator?> {
        Binding(
            get: { dragState.dropIndicator },
            set: { dragState.setDropIndicator($0) }
        )
    }

    /// Computed in the parent so `SidebarEmptyArea` can render its top-edge
    /// indicator from a value snapshot without holding a `SidebarDragState`
    /// reference (snapshot-boundary rule). Delegates to a pure predicate so
    /// the logic is unit-testable in isolation from view state.
    private func emptyAreaTopDropIndicatorVisible() -> Bool {
        let reorderIds = tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            usesTopLevelRows: dragState.dropIndicatorUsesTopLevelRows
        )
        return SidebarTabDropIndicatorPredicate.emptyAreaTopVisible(
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            lastTabId: reorderIds.last
        )
    }

    /// Constructs the drop delegate for the empty area in the parent scope,
    /// so the child view receives a closure-bundle-equivalent value rather
    /// than an `@Observable` store.
    private func emptyAreaTabDropDelegate() -> SidebarTabDropDelegate {
        SidebarTabDropDelegate(
            targetTabId: nil,
            tabManager: tabManager,
            dragState: dragState,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            targetRowHeight: nil,
            dragAutoScrollController: dragAutoScrollController
        )
    }

    private var sidebarTopScrimHeight: CGFloat {
        SidebarWorkspaceListMetrics.topScrimHeight
    }

    private var sidebarBottomScrimHeight: CGFloat {
        SidebarWorkspaceListMetrics.bottomScrimHeight
    }

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var titlebarDebugChromeSnapshot: MinimalModeTitlebarDebugSnapshot {
        MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarLeftControlsLeadingInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            ),
            leftControlsTopInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarLeftControlsTopInset,
                range: MinimalModeTitlebarDebugSettings.topInsetRange
            ),
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset,
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
        )
    }

    private var minimalModeSidebarTitlebarControlsTopPadding: CGFloat {
        guard let observedWindow else {
            return MinimalModeSidebarTitlebarControlsMetrics.topInset
        }
        return minimalModeSidebarTitlebarControlsTopInset(in: observedWindow)
    }

    private var showsSidebarNotificationMessage: Bool {
        tabItemSettingsStore.snapshot.showsNotificationMessage
    }

    private var workspaceNumberShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber)
    }

    private func requestSelectedWorkspaceScroll(_ proxy: ScrollViewProxy, workspaceIds: [UUID]) {
        guard let selectedWorkspaceId = tabManager.selectedTabId,
              workspaceIds.contains(selectedWorkspaceId) else {
            pendingSelectedWorkspaceScrollId = nil
            return
        }

        pendingSelectedWorkspaceScrollId = selectedWorkspaceId
        flushPendingSelectedWorkspaceScroll(proxy)
    }

    private func flushPendingSelectedWorkspaceScroll(
        _ proxy: ScrollViewProxy,
        laidOutWorkspaceRowIds: Set<UUID>? = nil
    ) {
        guard let selectedWorkspaceId = pendingSelectedWorkspaceScrollId else { return }
        let rowIds = laidOutWorkspaceRowIds ?? self.laidOutWorkspaceRowIds
        guard rowIds.contains(selectedWorkspaceId) else { return }

        // No anchor means SwiftUI scrolls the minimum needed to reveal the row.
        proxy.scrollTo(selectedWorkspaceId)
        pendingSelectedWorkspaceScrollId = nil
    }

    private func shouldRequestSelectedWorkspaceScrollAfterWorkspaceIdsChange(
        from oldWorkspaceIds: [UUID],
        to newWorkspaceIds: [UUID]
    ) -> Bool {
        SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: tabManager.selectedTabId,
            oldWorkspaceIds: oldWorkspaceIds,
            newWorkspaceIds: newWorkspaceIds
        )
    }

    private func requestSelectedWorkspaceScrollAfterWorkspaceOrderChange(_ notification: Notification) {
        guard let manager = notification.object as? TabManager, manager === tabManager else {
            return
        }
        guard let selectedWorkspaceId = tabManager.selectedTabId else { return }
        let movedWorkspaceIds = notification.userInfo?[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds] as? [UUID] ?? []
        guard movedWorkspaceIds.contains(selectedWorkspaceId) else { return }
        pendingSelectedWorkspaceScrollId = selectedWorkspaceId
    }

    struct WorkspaceListRenderContext {
        let tabs: [Workspace]
        /// Stored snapshot of `tabs.map(\.id)` so per-row predicates that need
        /// it (e.g. `SidebarTabDropIndicatorPredicate.topVisible`) don't pay
        /// O(n) per row.
        let tabIds: [UUID]
        /// Drag-scope row ids shared by every visible row for this render pass.
        let sidebarReorderIds: [UUID]
        let workspaceCount: Int
        let canCloseWorkspace: Bool
        let workspaceNumberShortcut: StoredShortcut
        let tabItemSettings: SidebarTabItemSettingsSnapshot
        let tabIndexById: [UUID: Int]
        let workspaceById: [UUID: Workspace]
        let selectedContextTargetIds: [UUID]
        let selectedRemoteContextMenuWorkspaceIds: [UUID]
        let allSelectedRemoteContextMenuTargetsConnecting: Bool
        let allSelectedRemoteContextMenuTargetsDisconnected: Bool
        let workspaceGroups: [WorkspaceGroup]
        let workspaceGroupById: [UUID: WorkspaceGroup]
        let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot

        var workspaceIds: [UUID] { tabIds }
    }

    var body: some View {
        let tabs = tabManager.tabs
        let workspaceCount = tabs.count
        let canCloseWorkspace = workspaceCount > 1
        let workspaceNumberShortcut = self.workspaceNumberShortcut
        let tabItemSettings = tabItemSettingsStore.snapshot
        let tabIndexById = Dictionary(uniqueKeysWithValues: tabs.enumerated().map {
            ($0.element.id, $0.offset)
        })
        let workspaceById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let orderedSelectedTabs = tabs.filter { selectedTabIds.contains($0.id) }
        let selectedContextTargetIds = orderedSelectedTabs.map(\.id)
        let selectedRemoteContextMenuTargets = orderedSelectedTabs.filter { $0.isRemoteWorkspace }
        let selectedRemoteContextMenuWorkspaceIds = selectedRemoteContextMenuTargets.map(\.id)
        let allSelectedRemoteContextMenuTargetsConnecting = !selectedRemoteContextMenuTargets.isEmpty &&
            selectedRemoteContextMenuTargets.allSatisfy {
                $0.remoteConnectionState == .connecting || $0.remoteConnectionState == .reconnecting
            }
        let allSelectedRemoteContextMenuTargetsDisconnected = !selectedRemoteContextMenuTargets.isEmpty &&
            selectedRemoteContextMenuTargets.allSatisfy { $0.remoteConnectionState == .disconnected }
        let workspaceGroups = tabManager.workspaceGroups
        let workspaceGroupById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let workspaceGroupMenuSnapshot = WorkspaceGroupMenuSnapshot(
            items: workspaceGroups.map { WorkspaceGroupMenuSnapshot.Item(id: $0.id, name: $0.name) }
        )
        let draggedSidebarTabId = dragState.draggedTabId
        let sidebarReorderIds = draggedSidebarTabId.map {
            tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: $0,
                usesTopLevelRows: dragState.dropIndicatorUsesTopLevelRows
            )
        } ?? []
        let renderContext = WorkspaceListRenderContext(
            tabs: tabs,
            tabIds: tabs.map(\.id),
            sidebarReorderIds: sidebarReorderIds,
            workspaceCount: workspaceCount,
            canCloseWorkspace: canCloseWorkspace,
            workspaceNumberShortcut: workspaceNumberShortcut,
            tabItemSettings: tabItemSettings,
            tabIndexById: tabIndexById,
            workspaceById: workspaceById,
            selectedContextTargetIds: selectedContextTargetIds,
            selectedRemoteContextMenuWorkspaceIds: selectedRemoteContextMenuWorkspaceIds,
            allSelectedRemoteContextMenuTargetsConnecting: allSelectedRemoteContextMenuTargetsConnecting,
            allSelectedRemoteContextMenuTargetsDisconnected: allSelectedRemoteContextMenuTargetsDisconnected,
            workspaceGroups: workspaceGroups,
            workspaceGroupById: workspaceGroupById,
            workspaceGroupMenuSnapshot: workspaceGroupMenuSnapshot
        )

        ZStack(alignment: .bottomLeading) {
            if CmuxExtensionSidebarSelection.descriptor(for: effectiveExtensionSidebarProviderId).id == CmuxSidebarProviderDescriptor.defaultWorkspacesID {
                workspaceScrollArea(renderContext: renderContext)
            } else {
                extensionSidebarScrollArea(renderContext: renderContext)
            }
            SidebarFooter(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, onSendFeedback: onSendFeedback)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("Sidebar")
        .ignoresSafeArea()
        .overlay(alignment: .trailing) {
            SidebarTrailingBorder()
        }
        .background(
            WindowAccessor { window in
                modifierKeyMonitor.setHostWindow(window)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            modifierKeyMonitor.start()
            dragState.clearDrag()
            isBonsplitWorkspaceDropTargetCollectionActive = false
            // Defensive reset: if a prior simulation died without running
            // its teardown (sidebar unmounted mid-loop, app crash, etc.) the
            // @State SidebarDragState could carry isSimulated=true into a
            // re-mount, which would silently bypass the real-drag failsafe.
            dragState.isSimulated = false
            #if DEBUG
            SidebarDragStateRegistry.register(windowId: windowId, dragState: dragState)
            #endif
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: nil,
                reason: "sidebar_appear"
            )
        }
        .onDisappear {
            modifierKeyMonitor.stop()
            dragAutoScrollController.stop()
            dragFailsafeMonitor.stop()
            dragState.clearDrag()
            isBonsplitWorkspaceDropTargetCollectionActive = false
            // Clear the simulator flag too so a re-mounted sidebar doesn't
            // inherit a stale bypass and skip the real-drag failsafe monitor.
            dragState.isSimulated = false
            #if DEBUG
            SidebarDragStateRegistry.unregister(windowId: windowId)
            #endif
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: nil,
                reason: "sidebar_disappear"
            )
        }
        .onChange(of: dragState.draggedTabId) { newDraggedTabId in
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: newDraggedTabId,
                reason: "drag_state_change"
            )
#if DEBUG
            cmuxDebugLog("sidebar.dragState.sidebar tab=\(debugShortSidebarTabId(newDraggedTabId))")
#endif
            if newDraggedTabId != nil {
                // The failsafe monitor probes the real mouse-button state and
                // posts `mouse_up_failsafe` if no mouse is held down. That's
                // correct for HID-driven drags, but `debug.sidebar.simulate_drag`
                // drives the state without any mouse, so skip the monitor when
                // a simulated drag is in flight.
                if !dragState.isSimulated {
                    dragFailsafeMonitor.start {
                        SidebarDragLifecycleNotification.postClearRequest(reason: $0)
                    }
                }
                return
            }
            dragFailsafeMonitor.stop()
            dragAutoScrollController.stop()
            dragState.clearDropIndicator()
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.requestClear)) { notification in
            guard dragState.draggedTabId != nil || dragState.dropIndicator != nil else { return }
            let reason = SidebarDragLifecycleNotification.reason(from: notification)
#if DEBUG
            cmuxDebugLog("sidebar.dragClear tab=\(debugShortSidebarTabId(dragState.draggedTabId)) reason=\(reason)")
#endif
            dragState.clearDrag()
        }
        .onChange(of: tabManager.tabs.map(\.id)) { tabIds in
            guard let frozenTabId = frozenShortcutHintsTabId,
                  !tabIds.contains(frozenTabId) else { return }
            frozenShortcutHintsTabId = nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func workspaceScrollArea(renderContext: WorkspaceListRenderContext) -> some View {
        let scrollInsets = SidebarWorkspaceScrollInsets.workspaceList
        return GeometryReader { geometryProxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    workspaceScrollContent(
                        renderContext: renderContext,
                        minHeight: SidebarWorkspaceScrollLayout.contentMinHeight(
                            viewportHeight: geometryProxy.size.height,
                            insets: scrollInsets
                        )
                    )
                }
                .background(
                    SidebarScrollViewResolver { scrollView in
                        dragAutoScrollController.attach(scrollView: scrollView)
                    }
                    .frame(width: 0, height: 0)
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: scrollInsets.top)
                        .allowsHitTesting(false)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: scrollInsets.bottom)
                        .allowsHitTesting(false)
                }
                .mask(
                    SidebarWorkspaceScrollEdgeFadeMask(
                        topHeight: sidebarTopScrimHeight,
                        bottomHeight: sidebarBottomScrimHeight
                    )
                )
                .overlay(alignment: .top) {
                    // The sidebar top strip remains draggable and handles
                    // double-clicks with the standard titlebar action.
                    WindowDragHandleView()
                        .frame(height: sidebarTitlebarInteractionHeight)
                        .background(TitlebarDoubleClickMonitorView())
                }
                .overlay(alignment: .top) {
                    if dragState.draggedTabId != nil, let firstWorkspaceId = renderContext.workspaceIds.first {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(height: scrollInsets.top + 8)
                            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: SidebarTabDropDelegate(
                                targetTabId: firstWorkspaceId,
                                tabManager: tabManager,
                                dragState: dragState,
                                selectedTabIds: $selectedTabIds,
                                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                                targetRowHeight: nil,
                                dragAutoScrollController: dragAutoScrollController
                            ))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isMinimalMode {
                        HiddenTitlebarSidebarControlsView(
                            notificationStore: notificationStore,
                            onToggleSidebar: onToggleSidebar,
                            onToggleNotifications: { anchorView in
                                AppDelegate.shared?.toggleNotificationsPopover(
                                    animated: true,
                                    anchorView: anchorView
                                )
                            },
                            onNewTab: onNewTab,
                            onFocusHistoryBack: {
                                if !tabManager.navigateBack() {
                                    NSSound.beep()
                                }
                            },
                            onFocusHistoryForward: {
                                if !tabManager.navigateForward() {
                                    NSSound.beep()
                                }
                            }
                        )
                            .padding(
                                .leading,
                                CGFloat(titlebarDebugChromeSnapshot.leftControlsLeadingInset)
                            )
                            .padding(
                                .top,
                                minimalModeSidebarTitlebarControlsTopPadding
                            )
                    }
                }
                .background(Color.clear)
                .modifier(ClearScrollBackground())
                .onAppear {
                    requestSelectedWorkspaceScroll(scrollProxy, workspaceIds: renderContext.workspaceIds)
                }
                .onChange(of: tabManager.selectedTabId) { _, _ in
                    requestSelectedWorkspaceScroll(scrollProxy, workspaceIds: renderContext.workspaceIds)
                }
                .onChange(of: renderContext.workspaceIds) { oldWorkspaceIds, newWorkspaceIds in
                    guard shouldRequestSelectedWorkspaceScrollAfterWorkspaceIdsChange(
                        from: oldWorkspaceIds,
                        to: newWorkspaceIds
                    ) else {
                        flushPendingSelectedWorkspaceScroll(scrollProxy)
                        return
                    }
                    requestSelectedWorkspaceScroll(scrollProxy, workspaceIds: newWorkspaceIds)
                }
                .onReceive(NotificationCenter.default.publisher(for: .workspaceOrderDidChange)) { notification in
                    requestSelectedWorkspaceScrollAfterWorkspaceOrderChange(notification)
                }
                .onReceive(NotificationCenter.default.publisher(for: .workspaceCurrentDirectoryDidChange)) { _ in
                    // Drive a revision counter that the group-header resolver
                    // reads. Forces SwiftUI to re-invoke `cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd:)`
                    // when the anchor's cwd changes while the anchor is not
                    // the selected workspace — otherwise group color/icon/menu
                    // and `+` placement reflect the previous cwd until some
                    // unrelated sidebar event fires.
                    anchorCwdRevision &+= 1
                }
                .onReceive(NotificationCenter.default.publisher(for: .sidebarMultiSelectionDidHide)) { notification in
                    // Group collapse hides some workspaces without changing
                    // focus or wiping the rest of the multi-selection. Strip
                    // only the hidden ids; if focus moved, make sure the new
                    // focused id is still represented.
                    guard let manager = notification.object as? TabManager,
                          manager === tabManager,
                          let hidden = notification.userInfo?[SidebarMultiSelectionHideKey.hiddenWorkspaceIds] as? Set<UUID> else { return }
                    var next = selectedTabIds.subtracting(hidden)
                    if let movedFocus = notification.userInfo?[SidebarMultiSelectionHideKey.focusedWorkspaceId] as? UUID {
                        next.insert(movedFocus)
                        if let index = tabManager.tabs.firstIndex(where: { $0.id == movedFocus }) {
                            lastSidebarSelectionIndex = index
                        }
                    }
                    if next != selectedTabIds {
                        selectedTabIds = next
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .sidebarMultiSelectionShouldCollapse)) { notification in
                    // Keyboard nav (selectNextTab/selectPreviousTab) posts
                    // this so any stale Shift-click range in the sidebar's
                    // SwiftUI selectedTabIds collapses to just the newly-
                    // focused workspace. Without this, batch context-menu /
                    // shortcut actions would still target the stale range.
                    guard let manager = notification.object as? TabManager,
                          manager === tabManager,
                          let focusedId = notification.userInfo?[SidebarMultiSelectionCollapseKey.focusedWorkspaceId] as? UUID else { return }
                    let next: Set<UUID> = tabManager.tabs.contains(where: { $0.id == focusedId }) ? [focusedId] : []
                    if selectedTabIds != next {
                        selectedTabIds = next
                    }
                    if let index = tabManager.tabs.firstIndex(where: { $0.id == focusedId }) {
                        lastSidebarSelectionIndex = index
                    }
                }
                .onPreferenceChange(SidebarWorkspaceRowIdsPreferenceKey.self) { rowIds in
                    laidOutWorkspaceRowIds = rowIds
                    flushPendingSelectedWorkspaceScroll(scrollProxy, laidOutWorkspaceRowIds: rowIds)
                }
            }
        }
    }

    @ViewBuilder
    private func extensionSidebarScrollArea(renderContext: WorkspaceListRenderContext) -> some View {
        if effectiveExtensionSidebarProviderId == CmuxExtensionSidebarSelection.hostedExtensionsProviderId {
            CMUXInstalledExtensionSidebarHostView(
                snapshotProvider: { cmuxSidebarSnapshotForCurrentTabs() },
                snapshotUpdateToken: extensionSidebarUpdateToken,
                actionHandler: { handleCMUXSidebarExtensionAction($0) },
                onUseDefaultSidebar: {
                    CmuxExtensionSidebarSelection.setProviderId(CmuxSidebarProviderDescriptor.defaultWorkspacesID)
                }
            )
            .onReceive(
                extensionSidebarImmediateObservationPublisher(renderContext: renderContext)
                    .receive(on: RunLoop.main)
            ) { _ in
                refreshExtensionSidebarSnapshot()
            }
            .onReceive(
                extensionSidebarDebouncedObservationPublisher(renderContext: renderContext)
                    .receive(on: RunLoop.main)
                    .debounce(for: Self.extensionSidebarObservationCoalesceInterval, scheduler: RunLoop.main)
            ) { _ in
                refreshExtensionSidebarSnapshot()
            }
            // Fade the extension's content out at the bottom so it dissolves behind the
            // sidebar footer instead of overlapping it sharply, matching the default
            // workspace sidebar's bottom scrim. Top stays sharp so the control strip
            // remains crisp.
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: 0,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
        } else if effectiveExtensionSidebarProviderId.hasPrefix(CmuxExtensionSidebarSelection.customSidebarProviderPrefix),
                  let customSidebarURL = CmuxExtensionSidebarSelection.customSidebarFileURL(forProviderId: effectiveExtensionSidebarProviderId) {
            // Periodic tick so the custom sidebar re-renders live (clock,
            // countdowns, and refreshed workspace/data context), mirroring the
            // default sidebar's TimelineView. No banned timers involved.
            // Fully out-of-process: the render worker interprets AND renders
            // the file; this view only hosts the worker's remote layer and
            // forwards input, so no file-derived view code runs in the host.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                // No .id(customSidebarURL): the worker swaps files in place on
                // the next scene message, so remounting the surface would only
                // flash the previous sidebar's pixels during the switch.
                RemoteCustomSidebarHost(
                    fileURL: customSidebarURL,
                    dataContext: customSidebarDataContext(now: timeline.date),
                    dispatch: makeCmuxSidebarActionDispatch(),
                    contentInsets: CustomSidebarContentInsets(
                        top: SidebarWorkspaceScrollInsets.workspaceList.top,
                        bottom: SidebarWorkspaceScrollInsets.workspaceList.bottom
                    )
                )
            }
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: sidebarTopScrimHeight,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let model = extensionSidebarRenderModel(renderContext: renderContext, now: timeline.date)
                extensionSidebarTimelineContent(renderContext: renderContext, model: model, now: timeline.date)
            }
        }
    }

    private func extensionSidebarTimelineContent(
        renderContext: WorkspaceListRenderContext,
        model: CmuxSidebarProviderRenderModel,
        now: Date
    ) -> some View {
        GeometryReader { geometryProxy in
            ScrollView {
                if model.presentation == .browserStack {
                    extensionBrowserStackSidebar(model: model, now: now)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: SidebarWorkspaceScrollLayout.contentMinHeight(
                                viewportHeight: geometryProxy.size.height,
                                insets: SidebarWorkspaceScrollInsets.workspaceList
                            ),
                            alignment: .topLeading
                        )
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.sections) { section in
                            extensionSidebarSection(section, providerId: model.providerId, now: now)
                        }

                        SidebarEmptyArea(
                            rowSpacing: tabRowSpacing,
                            selection: $selection,
                            selectedTabIds: $selectedTabIds,
                            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                            dragAutoScrollController: dragAutoScrollController,
                            topDropIndicatorVisible: emptyAreaTopDropIndicatorVisible(),
                            tabDropDelegate: emptyAreaTabDropDelegate(),
                            bonsplitDropIndicator: dropIndicatorBinding
                        )
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .padding(.top, SidebarWorkspaceListMetrics.rowVerticalPadding)
                    .padding(.bottom, SidebarWorkspaceListMetrics.rowVerticalPadding + 40)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SidebarWorkspaceScrollLayout.contentMinHeight(
                            viewportHeight: geometryProxy.size.height,
                            insets: SidebarWorkspaceScrollInsets.workspaceList
                        ),
                        alignment: .topLeading
                    )
                }
            }
            .background(
                SidebarScrollViewResolver { scrollView in
                    dragAutoScrollController.attach(scrollView: scrollView)
                }
                .frame(width: 0, height: 0)
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: SidebarWorkspaceScrollInsets.workspaceList.top)
                    .allowsHitTesting(false)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SidebarWorkspaceScrollInsets.workspaceList.bottom)
                    .allowsHitTesting(false)
            }
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: sidebarTopScrimHeight,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
            .overlay(alignment: .top) {
                WindowDragHandleView()
                    .frame(height: sidebarTitlebarInteractionHeight)
                    .background(TitlebarDoubleClickMonitorView())
            }
            .overlay(alignment: .topLeading) {
                if isMinimalMode {
                    HiddenTitlebarSidebarControlsView(
                        notificationStore: notificationStore,
                        onToggleSidebar: onToggleSidebar,
                        onToggleNotifications: { anchorView in
                            AppDelegate.shared?.toggleNotificationsPopover(
                                animated: true,
                                anchorView: anchorView
                            )
                        },
                        onNewTab: onNewTab,
                        onFocusHistoryBack: {
                            if !tabManager.navigateBack() {
                                NSSound.beep()
                            }
                        },
                        onFocusHistoryForward: {
                            if !tabManager.navigateForward() {
                                NSSound.beep()
                            }
                        }
                    )
                    .padding(
                        .leading,
                        CGFloat(titlebarDebugChromeSnapshot.leftControlsLeadingInset)
                    )
                    .padding(
                        .top,
                        minimalModeSidebarTitlebarControlsTopPadding
                    )
                }
            }
            .background(Color.clear)
            .modifier(ClearScrollBackground())
            .onReceive(
                extensionSidebarImmediateObservationPublisher(renderContext: renderContext)
                    .receive(on: RunLoop.main)
            ) { _ in
                refreshExtensionSidebarSnapshot()
            }
            .onReceive(
                    extensionSidebarDebouncedObservationPublisher(renderContext: renderContext)
                        .receive(on: RunLoop.main)
                        .debounce(for: Self.extensionSidebarObservationCoalesceInterval, scheduler: RunLoop.main)
                ) { _ in
                refreshExtensionSidebarSnapshot()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: BrowserStackSidebar.stateDidLoadNotification)
                    .receive(on: RunLoop.main)
            ) { _ in
                refreshExtensionSidebarSnapshot()
            }
        }
    }

    private func refreshExtensionSidebarSnapshot() {
        extensionSidebarUpdateToken &+= 1
    }

    private func extensionSidebarImmediateObservationPublisher(
        renderContext: WorkspaceListRenderContext
    ) -> AnyPublisher<Void, Never> {
        let publishers = renderContext.tabs.map(\.sidebarImmediateObservationPublisher)
        guard !publishers.isEmpty else {
            return Empty<Void, Never>().eraseToAnyPublisher()
        }
        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }

    private func extensionSidebarDebouncedObservationPublisher(
        renderContext: WorkspaceListRenderContext
    ) -> AnyPublisher<Void, Never> {
        let publishers = renderContext.tabs.map(\.sidebarObservationPublisher)
        guard !publishers.isEmpty else {
            return Empty<Void, Never>().eraseToAnyPublisher()
        }
        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }

    private func extensionSidebarRenderModel(
        renderContext: WorkspaceListRenderContext,
        now: Date
    ) -> CmuxSidebarProviderRenderModel {
        let _ = extensionSidebarUpdateToken
        let snapshot = extensionSidebarSnapshot(renderContext: renderContext)
        return extensionSidebarRenderModel(snapshot: snapshot, now: now)
    }

    private func extensionSidebarRenderModel(
        snapshot: CmuxSidebarProviderSnapshot,
        now: Date
    ) -> CmuxSidebarProviderRenderModel {
        let descriptor = CmuxExtensionSidebarSelection.descriptor(for: effectiveExtensionSidebarProviderId)
        if let provider = CmuxExtensionSidebarSelection.provider(for: descriptor.id) {
            let context = CmuxSidebarProviderRenderContext(now: now)
            if let contextualProvider = provider as? any CmuxContextualSidebarProvider {
                return contextualProvider.render(snapshot: snapshot, context: context)
            }
            return provider.render(snapshot: snapshot)
        }
        return CmuxSidebarProviderRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: []
        )
    }

    private func extensionSidebarSnapshot(
        renderContext: WorkspaceListRenderContext
    ) -> CmuxSidebarProviderSnapshot {
        extensionSidebarSnapshot(workspaces: renderContext.tabs)
    }

    private func extensionSidebarSnapshotForCurrentTabs() -> CmuxSidebarProviderSnapshot {
        extensionSidebarSnapshot(workspaces: tabManager.tabs)
    }

    private func cmuxSidebarSnapshotForCurrentTabs() -> CmuxSidebarSnapshot {
        let snapshot = extensionSidebarSnapshotForCurrentTabs()
        return CmuxSidebarSnapshot(
            sequence: snapshot.sequence,
            windowID: snapshot.windowId,
            selectedWorkspaceID: snapshot.selectedWorkspaceId,
            workspaces: snapshot.workspaces.map { workspace in
                CmuxSidebarWorkspace(
                    id: workspace.id,
                    title: workspace.title,
                    detail: workspace.customDescription,
                    isPinned: workspace.isPinned,
                    rootPath: workspace.rootPath,
                    projectRootPath: workspace.projectRootPath,
                    gitBranch: workspace.branchSummary,
	                    unreadCount: workspace.unreadCount,
	                    latestNotification: workspace.latestNotificationText,
	                    listeningPorts: workspace.listeningPorts,
	                    pullRequestURLs: workspace.pullRequestURLs,
	                    surfaces: cmuxSidebarSurfaces(for: workspace)
	                )
	            }
	        )
	    }

    private func cmuxSidebarSurfaces(for workspace: CmuxSidebarProviderWorkspace) -> [CmuxSidebarSurface] {
        guard let liveWorkspace = tabManager.tabs.first(where: { $0.id == workspace.id }) else { return [] }
        return liveWorkspace.sidebarOrderedPanelIds().compactMap { panelId in
            guard let panel = liveWorkspace.panels[panelId] else { return nil }
            return CmuxSidebarSurface(
                id: panelId,
                title: liveWorkspace.panelTitle(panelId: panelId) ?? panel.displayTitle,
                kind: cmuxSidebarSurfaceKind(for: panel.panelType),
                isFocused: liveWorkspace.focusedPanelId == panelId,
                isPinned: liveWorkspace.isPanelPinned(panelId),
                unreadCount: liveWorkspace.manualUnreadPanelIds.contains(panelId) ? 1 : 0,
                workingDirectory: liveWorkspace.panelDirectories[panelId]
            )
        }
    }

    private func cmuxSidebarSurfaceKind(for panelType: PanelType) -> CmuxSidebarSurfaceKind {
        switch panelType {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .rightSidebarTool:
            return .rightSidebarTool
        case .agentSession:
            return .agentSession
        case .project:
            return .project
        case .extensionBrowser:
            return .unknown
        }
    }

    private func handleCMUXSidebarExtensionAction(
        _ action: CmuxSidebarAction
    ) -> CmuxSidebarActionResult {
        switch action {
        case .createWorkspace(let title, let workingDirectory, let select):
            let workspace = tabManager.addWorkspace(
                title: title,
                workingDirectory: workingDirectory,
                inheritWorkingDirectory: workingDirectory == nil,
                select: select
            )
            return CmuxSidebarActionResult(accepted: true, message: workspace.id.uuidString)

        case .selectWorkspace(let workspaceId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found")
                )
            }
            tabManager.selectWorkspace(workspace)
            return .accepted

        case .closeWorkspace(let workspaceId):
            guard tabManager.closeWorkspaceWithConfirmation(tabId: workspaceId) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.closeRejected", defaultValue: "Workspace could not be closed")
                )
            }
            return .accepted

        case .selectNextWorkspace:
            tabManager.selectNextTab()
            return .accepted

        case .selectPreviousWorkspace:
            tabManager.selectPreviousTab()
            return .accepted

        case .createTerminalSurface(let workspaceId):
            guard let workspace = workspaceId.flatMap({ id in tabManager.tabs.first(where: { $0.id == id }) }) ?? tabManager.selectedWorkspace else {
                return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
            }
            if tabManager.selectedTabId != workspace.id {
                tabManager.selectWorkspace(workspace)
            }
            let panel = workspace.newTerminalSurfaceInFocusedPane(focus: true, initialInput: nil)
            return panel.map { CmuxSidebarActionResult(accepted: true, message: $0.id.uuidString) }
                ?? .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))

        case .createBrowserSurface(let workspaceId, let urlString):
            let validatedURL = cmuxSidebarExtensionOptionalHTTPURL(from: urlString)
            guard validatedURL.accepted else {
                return .rejected(String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened"))
            }
            guard let workspace = workspaceId.flatMap({ id in tabManager.tabs.first(where: { $0.id == id }) }) ?? tabManager.selectedWorkspace else {
                return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
            }
            if tabManager.selectedTabId != workspace.id {
                tabManager.selectWorkspace(workspace)
            }
            let panelId = tabManager.createBrowserSplit(direction: .right, url: validatedURL.url)
            return panelId.map { CmuxSidebarActionResult(accepted: true, message: $0.uuidString) }
                ?? .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))

        case .selectSurface(let workspaceId, let surfaceId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  workspace.panels[surfaceId] != nil else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
            }
            tabManager.selectWorkspace(workspace)
            workspace.focusPanel(surfaceId)
            return .accepted

        case .selectNextSurface:
            tabManager.selectNextSurface()
            return .accepted

        case .selectPreviousSurface:
            tabManager.selectPreviousSurface()
            return .accepted

        case .closeSurface(let workspaceId, let surfaceId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
            }
            guard workspace.panels[surfaceId] != nil else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
            }
            tabManager.closePanelWithConfirmation(tabId: workspaceId, surfaceId: surfaceId)
            return .accepted

        case .splitTerminal(let workspaceId, let surfaceId, let direction):
            guard let splitDirection = splitDirection(from: direction),
                  let panelId = tabManager.createSplit(tabId: workspaceId, surfaceId: surfaceId, direction: splitDirection) else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))
            }
            return CmuxSidebarActionResult(accepted: true, message: panelId.uuidString)

        case .splitBrowser(let workspaceId, let surfaceId, let direction, let urlString):
            let validatedURL = cmuxSidebarExtensionOptionalHTTPURL(from: urlString)
            guard validatedURL.accepted else {
                return .rejected(String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened"))
            }
            guard let splitDirection = splitDirection(from: direction),
                  let tab = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  tab.panels[surfaceId] != nil else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))
            }
            tabManager.selectWorkspace(tab)
            tab.focusPanel(surfaceId)
            let panelId = tabManager.createBrowserSplit(direction: splitDirection, url: validatedURL.url)
            return panelId.map { CmuxSidebarActionResult(accepted: true, message: $0.uuidString) }
                ?? .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))

        case .toggleSurfaceZoom(let workspaceId, let surfaceId):
            guard tabManager.toggleSplitZoom(tabId: workspaceId, surfaceId: surfaceId) else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
            }
            return .accepted

        case .openURL(let urlString):
            guard let url = cmuxSidebarExtensionRequiredHTTPURL(from: urlString),
                  NSWorkspace.shared.open(url) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened")
                )
            }
            return .accepted
        }
    }

    private func cmuxSidebarExtensionOptionalHTTPURL(from urlString: String?) -> (url: URL?, accepted: Bool) {
        guard let urlString, !urlString.isEmpty else {
            return (nil, true)
        }
        guard let url = cmuxSidebarExtensionRequiredHTTPURL(from: urlString) else {
            return (nil, false)
        }
        return (url, true)
    }

    private func cmuxSidebarExtensionRequiredHTTPURL(from urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    private func splitDirection(from direction: CmuxSidebarSplitDirection) -> SplitDirection? {
        switch direction {
        case .left:
            return .left
        case .right:
            return .right
        case .up:
            return .up
        case .down:
            return .down
        }
    }

    private func extensionSidebarSnapshot(workspaces: [Workspace]) -> CmuxSidebarProviderSnapshot {
        CmuxSidebarProviderSnapshot(
            sequence: UInt64(max(0, CmuxEventBus.shared.latestSequence)),
            selectedWorkspaceId: tabManager.selectedTabId,
            workspaces: workspaces.map(extensionWorkspaceSnapshot(for:)),
            windowId: windowId
        )
    }

    private func extensionWorkspaceSnapshot(for workspace: Workspace) -> CmuxSidebarProviderWorkspace {
        let rootPath = extensionSidebarRootPath(for: workspace)
        return CmuxSidebarProviderWorkspace(
            id: workspace.id,
            title: workspace.title,
            customDescription: workspace.customDescription,
            isPinned: workspace.isPinned,
            rootPath: rootPath,
            projectRootPath: workspace.extensionSidebarProjectRootPath,
            branchSummary: workspace.gitBranch?.branch,
            remoteDisplayTarget: workspace.remoteDisplayTarget,
            remoteConnectionState: workspace.remoteConnectionState.rawValue,
            unreadCount: notificationStore.unreadCount(forTabId: workspace.id),
            latestNotificationText: notificationStore.latestNotification(forTabId: workspace.id).flatMap {
                let text = $0.body.isEmpty ? $0.title : $0.body
                return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            },
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAt: workspace.latestSubmittedAt,
            listeningPorts: workspace.listeningPorts,
            pullRequestURLs: workspace.sidebarPullRequestsInDisplayOrder().map { $0.url.absoluteString },
            panelDirectories: workspace.sidebarDirectoriesInDisplayOrder(),
            gitBranches: workspace.sidebarGitBranchesInDisplayOrder().map {
                CmuxSidebarProviderGitBranch(branch: $0.branch, isDirty: $0.isDirty)
            }
        )
    }

    private func extensionSidebarRootPath(for workspace: Workspace) -> String? {
        workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func extensionBrowserStackSidebar(
        model: CmuxSidebarProviderRenderModel,
        now: Date
    ) -> some View {
        let rows = model.sections.flatMap(\.rows)
        let tileRows = model.sections.first { $0.id == "tiles" }?.rows ?? Array(rows.prefix(3))
        let looseRows = model.sections.first { $0.id == "loose" }?.rows ?? Array(rows.dropFirst(3).prefix(5))
        let groupedSections = model.sections.filter { $0.id != "tiles" && $0.id != "loose" && !$0.rows.isEmpty }
        let dropRows = extensionBrowserStackDropRows(for: model)

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(stride(from: 0, to: tileRows.count, by: 3)), id: \.self) { rowStart in
                    HStack(spacing: 8) {
                        ForEach(Array(tileRows[rowStart..<min(rowStart + 3, tileRows.count)].enumerated()), id: \.element.id) { offset, row in
                            let index = rowStart + offset
                            extensionBrowserStackTile(
                                row: row,
                                isSelected: row.workspaceId == tabManager.selectedTabId
                                    || (tabManager.selectedTabId == nil && index == 0),
                                dropRows: dropRows
                            )
                        }
                        if tileRows.count - rowStart < 3 {
                            ForEach(0..<(3 - (tileRows.count - rowStart)), id: \.self) { _ in
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 54)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(looseRows) { row in
                    extensionBrowserStackRow(
                        row: row,
                        now: now,
                        isSelected: row.workspaceId == tabManager.selectedTabId,
                        dropRows: dropRows
                    )
                }
            }
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(groupedSections) { section in
                    extensionBrowserStackGroup(section: section, now: now, dropRows: dropRows)
                }
            }

            Button(action: onNewTab) {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 22, height: 22)
                    Text(String(localized: "sidebar.browserStack.newTab", defaultValue: "New Tab"))
                        .font(.system(size: 13, weight: .regular))
                    Spacer(minLength: 0)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .safeHelp(String(localized: "sidebar.browserStack.newTab", defaultValue: "New Tab"))

            ExtensionSidebarBrowserStackEmptyArea(
                rowSpacing: tabRowSpacing,
                orderedRows: dropRows,
                dragAutoScrollController: dragAutoScrollController,
                draggedTabId: draggedTabIdBinding,
                dropIndicator: dropIndicatorBinding,
                onNewTab: onNewTab,
                onMove: { move in
                    handleExtensionSidebarMutation(.moveWorkspace(move))
                }
            )
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .padding(.bottom, SidebarWorkspaceListMetrics.rowVerticalPadding + 40)
    }

    private func extensionBrowserStackGroup(
        section: CmuxSidebarProviderSection,
        now: Date,
        dropRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.secondary)
                Text(extensionSidebarTreeSectionTitle(section.treeSection))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.86))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(section.rows) { row in
                    extensionBrowserStackRow(
                        row: row,
                        now: now,
                        compact: true,
                        isSelected: row.workspaceId == tabManager.selectedTabId,
                        dropRows: dropRows
                    )
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(.bottom, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 8)
    }

    private func extensionBrowserStackTile(
        row: CmuxSidebarProviderRow,
        isSelected: Bool,
        dropRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> some View {
        let targetRowHeight: CGFloat = 54

        return Button {
            selectExtensionSidebarWorkspace(row.workspaceId)
        } label: {
            extensionBrowserStackIcon(row.leadingIcon, size: 28)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            isSelected
                                ? Color(red: 0.44, green: 0.29, blue: 0.23).opacity(0.9)
                                : Color.primary.opacity(0.10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(
                                    isSelected ? Color.red.opacity(0.85) : Color.primary.opacity(0.08),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .safeHelp(row.title)
        .opacity(dragState.draggedTabId == row.workspaceId ? 0.55 : 1)
        .onDrag {
            dragState.beginDragging(tabId: row.workspaceId)
            return SidebarTabDragPayload.provider(for: row.workspaceId)
        }
        .internalOnlyTabDrag()
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackDropDelegate(
            targetWorkspaceId: row.workspaceId,
            orderedRows: dropRows,
            draggedTabId: draggedTabIdBinding,
            targetRowHeight: targetRowHeight,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: dropIndicatorBinding,
            onMove: { move in
                handleExtensionSidebarMutation(.moveWorkspace(move))
            }
        ))
        .overlay(alignment: .top) {
            extensionBrowserStackDropIndicator(row: row, edge: .top)
        }
        .overlay(alignment: .bottom) {
            extensionBrowserStackDropIndicator(row: row, edge: .bottom)
        }
        .contextMenu {
            extensionBrowserStackReorderMenu(row: row)
        }
        .accessibilityHint(Text(String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."
        )))
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: -1)
        }
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: 1)
        }
    }

    private func extensionBrowserStackRow(
        row: CmuxSidebarProviderRow,
        now: Date,
        compact: Bool = false,
        isSelected: Bool,
        dropRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> some View {
        let targetRowHeight: CGFloat = compact ? 34 : 38

        return Button {
            selectExtensionSidebarWorkspace(row.workspaceId)
        } label: {
            HStack(spacing: 9) {
                extensionBrowserStackIcon(row.leadingIcon, size: compact ? 22 : 24)
                Text(row.title)
                    .font(.system(size: compact ? 12.5 : 13, weight: .medium))
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let trailing = extensionSidebarRenderedText(row.trailingText, now: now) {
                    Text(trailing)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 6 : 7)
            .background(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .stroke(isSelected ? cmuxAccentColor().opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dragState.draggedTabId == row.workspaceId ? 0.55 : 1)
        .onDrag {
            dragState.beginDragging(tabId: row.workspaceId)
            return SidebarTabDragPayload.provider(for: row.workspaceId)
        }
        .internalOnlyTabDrag()
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackDropDelegate(
            targetWorkspaceId: row.workspaceId,
            orderedRows: dropRows,
            draggedTabId: draggedTabIdBinding,
            targetRowHeight: targetRowHeight,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: dropIndicatorBinding,
            onMove: { move in
                handleExtensionSidebarMutation(.moveWorkspace(move))
            }
        ))
        .overlay(alignment: .top) {
            extensionBrowserStackDropIndicator(row: row, edge: .top)
        }
        .overlay(alignment: .bottom) {
            extensionBrowserStackDropIndicator(row: row, edge: .bottom)
        }
        .contextMenu {
            extensionBrowserStackReorderMenu(row: row)
        }
        .accessibilityHint(Text(String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."
        )))
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: -1)
        }
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: 1)
        }
    }

    @ViewBuilder
    private func extensionBrowserStackDropIndicator(
        row: CmuxSidebarProviderRow,
        edge: SidebarDropEdge
    ) -> some View {
        if dragState.dropIndicator == SidebarDropIndicator(tabId: row.workspaceId, edge: edge) {
            Rectangle()
                .fill(cmuxAccentColor())
                .frame(height: 2)
                .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func extensionBrowserStackReorderMenu(row: CmuxSidebarProviderRow) -> some View {
        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: -1)
        }
        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: 1)
        }
    }

    private func moveExtensionBrowserStackWorkspace(_ workspaceId: UUID, by delta: Int) {
        let snapshot = extensionSidebarSnapshotForCurrentTabs()
        let model = extensionSidebarRenderModel(snapshot: snapshot, now: Date())
        let dropRows = extensionBrowserStackDropRows(for: model)
        guard let currentIndex = dropRows.firstIndex(where: { $0.workspaceId == workspaceId }) else { return }
        let targetIndex = min(max(currentIndex + delta, 0), dropRows.count - 1)
        guard targetIndex != currentIndex else { return }
        let insertionPosition = delta > 0 ? targetIndex + 1 : targetIndex
        guard let move = extensionBrowserStackMove(
            workspaceId: workspaceId,
            insertionPosition: insertionPosition,
            orderedRows: dropRows
        ) else {
            NSSound.beep()
            return
        }
        guard handleExtensionSidebarMutation(.moveWorkspace(move)) else {
            NSSound.beep()
            return
        }
    }

    private func handleExtensionSidebarMutation(_ mutation: CmuxSidebarProviderMutation) -> Bool {
        let descriptor = CmuxExtensionSidebarSelection.descriptor(for: effectiveExtensionSidebarProviderId)
        guard let provider = CmuxExtensionSidebarSelection.provider(for: descriptor.id) as? any CmuxMutableSidebarProvider else {
            return false
        }
        do {
            let result = try provider.handle(mutation, snapshot: extensionSidebarSnapshotForCurrentTabs())
            if result.ok {
                refreshExtensionSidebarSnapshot()
            }
            return result.ok
        } catch {
#if DEBUG
            cmuxDebugLog("extension.sidebar.mutation.failed provider=\(descriptor.id) error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    private func extensionBrowserStackDropRows(
        for model: CmuxSidebarProviderRenderModel
    ) -> [ExtensionSidebarBrowserStackDropRow] {
        model.sections.flatMap { section in
            section.rows.map { row in
                ExtensionSidebarBrowserStackDropRow(
                    workspaceId: row.workspaceId,
                    sectionId: section.id
                )
            }
        }
    }

    private func extensionBrowserStackMove(
        workspaceId: UUID,
        insertionPosition: Int,
        orderedRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> CmuxSidebarProviderWorkspaceMove? {
        ExtensionSidebarBrowserStackDropPlanner.move(
            draggedWorkspaceId: workspaceId,
            insertionPosition: insertionPosition,
            orderedRows: orderedRows
        )
    }

    private func extensionSidebarWorkspaceSnapshotsById(
        for rows: [CmuxSidebarProviderRow]
    ) -> [UUID: CmuxSidebarProviderWorkspace] {
        var snapshotsById: [UUID: CmuxSidebarProviderWorkspace] = [:]
        for row in rows where snapshotsById[row.workspaceId] == nil {
            snapshotsById[row.workspaceId] = extensionWorkspaceSnapshot(for: row.workspaceId)
        }
        return snapshotsById
    }

    private func extensionBrowserStackIcon(
        _ icon: CmuxSidebarProviderIcon?,
        size: CGFloat
    ) -> some View {
        let shape = icon?.shape ?? .circle
        let foreground = extensionSidebarColor(hex: icon?.foregroundColorHex, fallback: .primary)
        let background = extensionSidebarColor(hex: icon?.backgroundColorHex, fallback: Color.primary.opacity(0.16))
        return ZStack {
            if shape == .circle {
                Circle().fill(background)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(background)
            }
            if let systemImageName = icon?.systemImageName {
                Image(systemName: systemImageName)
                    .font(.system(size: size * 0.58, weight: .semibold))
                    .foregroundColor(foreground)
            } else {
                Text(icon?.text ?? ".")
                    .font(.system(size: size * 0.58, weight: .bold))
                    .foregroundColor(foreground)
            }
        }
        .frame(width: size, height: size)
    }

    private func extensionSidebarRenderedText(_ text: CmuxSidebarProviderText?, now: Date) -> String? {
        guard let text else { return nil }
        switch text {
        case .plain(let value):
            return value
        case .localized(let localized):
            return CmuxExtensionSidebarSelection.localizedText(localized)
        case .relativeDate(let date, _):
            return CmuxExtensionRelativeTimeFormatter.string(from: date, to: now)
        }
    }

    private func extensionSidebarColor(hex: String?, fallback: Color) -> Color {
        guard let hex else { return fallback }
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6 else { return fallback }
        var value: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&value) else { return fallback }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    @ViewBuilder
    private func extensionSidebarSection(
        _ section: CmuxSidebarProviderSection,
        providerId: String,
        now: Date
    ) -> some View {
        let isCollapsed = collapsedExtensionSidebarSectionIds.contains(section.id)
        let canCreateWorktree = section.treeSection.projectRootPath != nil
        let selectedWorkspaceId = tabManager.selectedTabId
        let workspaceSnapshotsById = extensionSidebarWorkspaceSnapshotsById(for: section.rows)

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Button {
                    withAnimation(Self.extensionSidebarDisclosureAnimation) {
                        if isCollapsed {
                            collapsedExtensionSidebarSectionIds.remove(section.id)
                        } else {
                            collapsedExtensionSidebarSectionIds.insert(section.id)
                        }
                    }
                } label: {
                    Image(systemName: isCollapsed ? "folder" : "folder.fill")
                        .font(.system(size: 13, weight: .regular))
                        .offset(y: -0.5)
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "sidebar.extension.toggleSection", defaultValue: "Toggle section"))

                Text(extensionSidebarTreeSectionTitle(section.treeSection))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if canCreateWorktree {
                    Button {
                        createExtensionWorktreeWorkspace(for: section.treeSection)
                    } label: {
                        Image(systemName: extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id) ? "clock" : "plus")
                            .font(.system(size: 11, weight: .regular))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .disabled(extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id))
                    .safeHelp(String(localized: "sidebar.extension.createWorktree", defaultValue: "Create worktree"))
                    .accessibilityIdentifier("ExtensionSidebarCreateWorktreeButton.\(section.id)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(section.rows) { row in
                        CmuxExtensionSidebarWorkspaceRowView(
                            row: row,
                            workspace: workspaceSnapshotsById[row.workspaceId],
                            providerId: providerId,
                            relativeNow: now,
                            isSelected: row.workspaceId == selectedWorkspaceId,
                            onSelect: selectExtensionSidebarWorkspace,
                            onOpenWindow: CmuxExtensionSidebarInspectorWindowController.show
                        )
                        .id(row.id)
                        .accessibilityIdentifier("extensionSidebar.workspace.\(row.workspaceId.uuidString)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func extensionWorkspaceSnapshot(for workspaceId: UUID) -> CmuxSidebarProviderWorkspace? {
        tabManager.tabs.first { $0.id == workspaceId }.map(extensionWorkspaceSnapshot(for:))
    }

    private func extensionSidebarTreeSectionTitle(_ section: CmuxSidebarProviderTreeSection) -> String {
        if let titleText = section.titleText {
            return CmuxExtensionSidebarSelection.localizedText(titleText)
        }
        return section.title
    }

    private func selectExtensionSidebarWorkspace(_ workspaceId: UUID) {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
        selection = .tabs
        selectedTabIds = [workspaceId]
        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == workspaceId }
        tabManager.selectWorkspace(workspace)
    }

    private func createExtensionWorktreeWorkspace(for section: CmuxSidebarProviderTreeSection) {
        guard let projectRootPath = section.projectRootPath,
              !extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id) else {
            return
        }

        extensionSidebarWorktreeCreationInFlightSectionIds.insert(section.id)
        Task {
            do {
                let result = try await CmuxExtensionWorktreePrototype.createWorktree(projectRootPath: projectRootPath)
                let spawnArgs = result.workspaceSpawnArgs()
                tabManager.addWorkspace(
                    title: spawnArgs.title,
                    workingDirectory: spawnArgs.workingDirectory,
                    initialTerminalInput: spawnArgs.initialTerminalInput,
                    inheritWorkingDirectory: spawnArgs.inheritWorkingDirectory,
                    select: true,
                    eagerLoadTerminal: false,
                    autoWelcomeIfNeeded: spawnArgs.initialTerminalInput == nil
                )
            } catch {
                NSSound.beep()
#if DEBUG
                cmuxDebugLog("extensionSidebar.worktree.failed project=\(projectRootPath) error=\(error.localizedDescription)")
#endif
            }
            extensionSidebarWorktreeCreationInFlightSectionIds.remove(section.id)
        }
    }

    private func workspaceScrollContent(
        renderContext: WorkspaceListRenderContext,
        minHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            workspaceRows(renderContext: renderContext)

            SidebarEmptyArea(
                rowSpacing: tabRowSpacing,
                selection: $selection,
                selectedTabIds: $selectedTabIds,
                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                dragAutoScrollController: dragAutoScrollController,
                topDropIndicatorVisible: emptyAreaTopDropIndicatorVisible(),
                tabDropDelegate: emptyAreaTabDropDelegate(),
                bonsplitDropIndicator: dropIndicatorBinding
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: minHeight, alignment: .top)
    }

    @ViewBuilder
    private func workspaceRows(renderContext: WorkspaceListRenderContext) -> some View {
        let renderItems = SidebarWorkspaceRenderItem.renderItems(
            tabs: renderContext.tabs,
            groupsById: renderContext.workspaceGroupById
        )
        let shouldCollectWorkspaceDropTargets = SidebarDropPlanner.shouldCollectWorkspaceDropTargets(
            draggedTabId: dragState.draggedTabId,
            isBonsplitWorkspaceDropActive: isBonsplitWorkspaceDropTargetCollectionActive
        )
        // LazyVStack is safe here because `dragState` is @Observable:
        // drag mutations at 60fps invalidate only the rows/overlays that
        // read them, never this sidebar body. See SidebarDragState and
        // https://github.com/manaflow-ai/cmux/issues/2586.
        let rows = LazyVStack(spacing: tabRowSpacing) {
            ForEach(renderItems, id: \.id) { item in
                switch item {
                case .groupHeader(let group, let memberWorkspaceIds):
                    sidebarWorkspaceGroupHeader(
                        group: group,
                        memberWorkspaceIds: memberWorkspaceIds,
                        renderContext: renderContext,
                        shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets
                    )
                case .workspace(let tab):
                    workspaceRow(
                        tab,
                        renderContext: renderContext,
                        shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets
                    )
                }
            }
        }
        .padding(.vertical, SidebarWorkspaceListMetrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)

        // Gate ONLY the per-row frame-anchor *reader* (the virtualization-defeating
        // work) behind the drag-active check, and keep the Bonsplit drop-capture
        // overlay mounted *outside* that conditional. Returning the overlay from both
        // branches of an `if`/`else` gives it distinct SwiftUI identity, so flipping the
        // gate mid-drag (draggingEntered -> shouldCollect=true) tore down and recreated
        // the drop NSView, orphaning the in-flight drag. Applying it at the stable outer
        // level keeps the NSView identity-stable across gate flips. (#5325 review)
        rowsWithGatedDropTargetReader(
            rows: rows,
            renderContext: renderContext,
            shouldCollect: shouldCollectWorkspaceDropTargets
        )
        .overlay {
            bonsplitWorkspaceDropOverlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Conditionally installs the row-frame `overlayPreferenceValue` reader (the part
    /// that defeats `LazyVStack` virtualization) only while a drag is collecting drop
    /// targets. Kept separate from the always-mounted drop-capture overlay so the gate
    /// flip never changes the drop NSView's identity. (#5325 review)
    @ViewBuilder
    private func rowsWithGatedDropTargetReader<Rows: View>(
        rows: Rows,
        renderContext: WorkspaceListRenderContext,
        shouldCollect: Bool
    ) -> some View {
        if shouldCollect {
            rows
                .overlayPreferenceValue(SidebarWorkspaceRowFramePreferenceKey.self) { anchors in
                    GeometryReader { proxy in
                        SidebarBonsplitTabWorkspaceDropOverlay.TargetWriter(
                            targetBridge: bonsplitWorkspaceDropTargetBridge,
                            targets: renderContext.tabs.compactMap { tab in
                                guard let anchor = anchors[tab.id] else { return nil }
                                return SidebarDropPlanner.WorkspaceDropTarget(
                                    workspaceId: tab.id,
                                    isPinned: tab.isPinned,
                                    frame: proxy[anchor]
                                )
                            }
                        )
                    }
                }
        } else {
            rows
        }
    }

    private func bonsplitWorkspaceDropOverlay() -> some View {
        SidebarBonsplitTabWorkspaceDropOverlay(
            currentSelectedTabId: {
                tabManager.selectedTabId
            },
            sidebarIndexForTabId: { workspaceId in
                tabManager.tabs.firstIndex { $0.id == workspaceId }
            },
            moveToExistingWorkspace: { workspaceId, transfer in
                guard let app = AppDelegate.shared else {
                    return false
                }
                if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
                   source.workspaceId == workspaceId {
                    return true
                }
                return app.moveBonsplitTab(
                    tabId: transfer.tab.id,
                    toWorkspace: workspaceId,
                    focus: true,
                    focusWindow: true
                )
            },
            moveToNewWorkspace: { insertionIndex, transfer in
                guard let app = AppDelegate.shared,
                      let result = app.moveBonsplitTabToNewWorkspace(
                        tabId: transfer.tab.id,
                        destinationManager: tabManager,
                        focus: true,
                        focusWindow: true,
                        insertionIndexOverride: insertionIndex
                      ) else {
                    return nil
                }
                return result.destinationWorkspaceId
            },
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            dropIndicator: dropIndicatorBinding,
            updateAutoscroll: {
                dragAutoScrollController.updateFromDragLocation()
            },
            setWorkspaceDropTargetCollectionActive: { isActive in
                guard isBonsplitWorkspaceDropTargetCollectionActive != isActive else { return }
                isBonsplitWorkspaceDropTargetCollectionActive = isActive
            },
            isWorkspaceDropTargetCollectionActive: isBonsplitWorkspaceDropTargetCollectionActive,
            targetBridge: bonsplitWorkspaceDropTargetBridge
        )
    }

    @ViewBuilder
    private func workspaceRow(
        _ tab: Workspace,
        renderContext: WorkspaceListRenderContext,
        shouldCollectWorkspaceDropTargets: Bool
    ) -> some View {
        let index = renderContext.tabIndexById[tab.id] ?? 0
        let usesSelectedContextMenuTargets = selectedTabIds.contains(tab.id)
        let contextMenuWorkspaceIds = usesSelectedContextMenuTargets
            ? renderContext.selectedContextTargetIds
            : [tab.id]
        let remoteContextMenuWorkspaceIds = usesSelectedContextMenuTargets
            ? renderContext.selectedRemoteContextMenuWorkspaceIds
            : (tab.isRemoteWorkspace ? [tab.id] : [])
        let allRemoteContextMenuTargetsConnecting = usesSelectedContextMenuTargets
            ? renderContext.allSelectedRemoteContextMenuTargetsConnecting
            : (
                tab.isRemoteWorkspace &&
                    (tab.remoteConnectionState == .connecting || tab.remoteConnectionState == .reconnecting)
            )
        let allRemoteContextMenuTargetsDisconnected = usesSelectedContextMenuTargets
            ? renderContext.allSelectedRemoteContextMenuTargetsDisconnected
            : (tab.isRemoteWorkspace && tab.remoteConnectionState == .disconnected)
        let contextMenuPinTarget = WorkspaceActionDispatcher.Target(
            workspaceIds: contextMenuWorkspaceIds,
            anchorWorkspaceId: tab.id
        )
        let contextMenuPinState = WorkspaceActionDispatcher.pinState(
            in: tabManager,
            target: contextMenuPinTarget
        )
        let liveUnreadCount = notificationStore.unreadCount(forTabId: tab.id)
        let liveLatestNotificationText: String? = {
            guard showsSidebarNotificationMessage,
                  let notification = notificationStore.latestNotification(forTabId: tab.id) else {
                return nil
            }
            let text = notification.body.isEmpty ? notification.title : notification.body
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let liveShowsModifierShortcutHints = modifierKeyMonitor.isModifierPressed
        let resolvedShowsModifierShortcutHints = SidebarShortcutHintFreezePolicy.resolved(
            live: liveShowsModifierShortcutHints,
            currentTabId: tab.id,
            frozenTabId: frozenShortcutHintsTabId,
            frozenValue: frozenShortcutHintsValue
        )
        let onContextMenuAppear: () -> Void = { [tabId = tab.id, snapshot = resolvedShowsModifierShortcutHints] in
            frozenShortcutHintsTabId = tabId
            frozenShortcutHintsValue = snapshot
        }
        let onContextMenuDisappear: () -> Void = { [tabId = tab.id] in
            if frozenShortcutHintsTabId == tabId {
                frozenShortcutHintsTabId = nil
            }
        }

        // Per-row drag/drop snapshots. Reading `dragState` here in the parent
        // is intentional: the parent owns the @Observable store, and these
        // value snapshots are what get passed to the row. The row's
        // Equatable conformance ignores closures, so rows whose snapshot is
        // unchanged skip re-render when drag state moves.
        let isBeingDragged = dragState.draggedTabId == tab.id
        let sidebarReorderIds = renderContext.sidebarReorderIds
        let topDropIndicatorVisible = SidebarTabDropIndicatorPredicate.topVisible(
            forTabId: tab.id,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: sidebarReorderIds
        )
        let onDragStart: () -> NSItemProvider = { [tabId = tab.id] in
            #if DEBUG
            cmuxDebugLog("sidebar.onDrag tab=\(tabId.uuidString.prefix(5))")
            #endif
            dragState.beginDragging(tabId: tabId)
            return SidebarTabDragPayload.provider(for: tabId)
        }
        let tabDropDelegateFactory: (CGFloat) -> SidebarTabDropDelegate = { [
            tabId = tab.id,
            selectedTabIds = $selectedTabIds,
            lastSidebarSelectionIndex = $lastSidebarSelectionIndex
        ] rowHeight in
            SidebarTabDropDelegate(
                targetTabId: tabId,
                tabManager: tabManager,
                dragState: dragState,
                selectedTabIds: selectedTabIds,
                lastSidebarSelectionIndex: lastSidebarSelectionIndex,
                targetRowHeight: rowHeight,
                dragAutoScrollController: dragAutoScrollController
            )
        }

        let row = TabItemView(
            tabManager: tabManager,
            notificationStore: notificationStore,
            tab: tab,
            index: index,
            isActive: tabManager.selectedTabId == tab.id,
            workspaceShortcutDigit: WorkspaceShortcutMapper.digitForWorkspace(
                at: index,
                workspaceCount: renderContext.workspaceCount
            ),
            workspaceShortcutModifierSymbol: renderContext.workspaceNumberShortcut.numberedDigitHintPrefix,
            canCloseWorkspace: renderContext.canCloseWorkspace,
            accessibilityWorkspaceCount: renderContext.workspaceCount,
            unreadCount: liveUnreadCount,
            latestNotificationText: liveLatestNotificationText,
            rowSpacing: tabRowSpacing,
            setSelectionToTabs: { selection = .tabs },
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            showsModifierShortcutHints: resolvedShowsModifierShortcutHints,
            dragAutoScrollController: dragAutoScrollController,
            isBeingDragged: isBeingDragged,
            topDropIndicatorVisible: topDropIndicatorVisible,
            onDragStart: onDragStart,
            tabDropDelegateFactory: tabDropDelegateFactory,
            contextMenuWorkspaceIds: contextMenuWorkspaceIds,
            remoteContextMenuWorkspaceIds: remoteContextMenuWorkspaceIds,
            allRemoteContextMenuTargetsConnecting: allRemoteContextMenuTargetsConnecting,
            allRemoteContextMenuTargetsDisconnected: allRemoteContextMenuTargetsDisconnected,
            contextMenuPinState: contextMenuPinState,
            workspaceGroupMenuSnapshot: renderContext.workspaceGroupMenuSnapshot,
            settings: renderContext.tabItemSettings,
            onContextMenuAppear: onContextMenuAppear,
            onContextMenuDisappear: onContextMenuDisappear
        )
        .equatable()
        .id(tab.id)
        .accessibilityIdentifier("sidebarWorkspace.\(tab.id.uuidString)")
        .preference(key: SidebarWorkspaceRowIdsPreferenceKey.self, value: Set([tab.id]))

        row
            .sidebarWorkspaceFrameAnchor(id: tab.id, isEnabled: shouldCollectWorkspaceDropTargets)
            .padding(.leading, tab.groupId != nil ? SidebarWorkspaceGroupingMetrics.memberIndent : 0)
    }

    private func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}

struct SidebarWorkspaceRowIdsPreferenceKey: PreferenceKey {
    static let defaultValue: Set<UUID> = []

    static func reduce(value: inout Set<UUID>, nextValue: () -> Set<UUID>) {
        value.formUnion(nextValue())
    }
}

struct SidebarWorkspaceFrameAnchorModifier: ViewModifier {
    let id: UUID
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.anchorPreference(key: SidebarWorkspaceRowFramePreferenceKey.self, value: .bounds) { anchor in
                [id: anchor]
            }
        } else {
            content
        }
    }
}

extension View {
    func sidebarWorkspaceFrameAnchor(id: UUID, isEnabled: Bool) -> some View {
        modifier(SidebarWorkspaceFrameAnchorModifier(id: id, isEnabled: isEnabled))
    }
}

struct SidebarWorkspaceRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, next in next }
    }
}

enum ShortcutHintModifierPolicy {
    static let intentionalHoldDelay: TimeInterval = 0.30

    static func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        switch normalized {
        case [.command]:
            return ShortcutHintDebugSettings.showHintsOnCommandHoldEnabled(defaults: defaults)
        case [.control]:
            return ShortcutHintDebugSettings.showHintsOnControlHoldEnabled(defaults: defaults)
        default:
            return false
        }
    }

    static func shouldShowControlHints(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard normalized == [.control] else { return false }
        return ShortcutHintDebugSettings.showHintsOnControlHoldEnabled(defaults: defaults)
    }

    static func shouldShowCommandHints(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard normalized == [.command] else { return false }
        return ShortcutHintDebugSettings.showHintsOnCommandHoldEnabled(defaults: defaults)
    }

    static func isCurrentWindow(
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?
    ) -> Bool {
        guard let hostWindowNumber, hostWindowIsKey else { return false }
        if let eventWindowNumber {
            return eventWindowNumber == hostWindowNumber
        }
        return keyWindowNumber == hostWindowNumber
    }

    static func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        shouldShowHints(for: modifierFlags, defaults: defaults) &&
            isCurrentWindow(
                hostWindowNumber: hostWindowNumber,
                hostWindowIsKey: hostWindowIsKey,
                eventWindowNumber: eventWindowNumber,
                keyWindowNumber: keyWindowNumber
            )
    }
}

enum ShortcutHintDebugSettings {
    static let defaultSidebarHintX = 0.0
    static let defaultSidebarHintY = 0.0
    static let defaultTitlebarHintX = 0.0
    static let defaultTitlebarHintY = -5.0
    static let defaultPaneHintX = 0.0
    static let defaultPaneHintY = 0.0
    static let defaultRightSidebarCloseHintX = -10.0
    static let defaultRightSidebarCloseHintY = 3.3
    static let defaultRightSidebarFocusHintX = -1.6
    static let defaultRightSidebarFocusHintY = 1.7
    static let defaultAlwaysShowHints = false
    static let defaultShowHintsOnCommandHold = true
    static let defaultShowHintsOnControlHold = true

    static let offsetRange: ClosedRange<Double> = -20...20

    static func clamped(_ value: Double) -> Double {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    static func alwaysShowHints(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        defaultAlwaysShowHints || environment["CMUX_UI_TEST_SHORTCUT_HINTS_ALWAYS_SHOW"] == "1"
    }

    static func showHintsOnCommandHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaultShowHintsOnCommandHold
    }

    static func showHintsOnControlHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaultShowHintsOnControlHold
    }

}

enum DevBuildBannerDebugSettings {
    static let sidebarBannerVisibleKey = "showSidebarDevBuildBanner"
    static let defaultShowSidebarBanner = true

    static func showSidebarBanner(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: sidebarBannerVisibleKey) != nil else {
            return defaultShowSidebarBanner
        }
        return defaults.bool(forKey: sidebarBannerVisibleKey)
    }
}
