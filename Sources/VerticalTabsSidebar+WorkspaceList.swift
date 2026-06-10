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


// MARK: - Workspace list rendering, scrolling, drag bindings
extension VerticalTabsSidebar {
    var sidebarTitlebarInteractionHeight: CGFloat {
        MinimalModeChromeMetrics.titlebarHeight
    }

    /// Adapter binding for unmigrated consumers (extension sidebar drop
    /// delegates, bonsplit overlays) that still expect @Binding<UUID?>. Reads
    /// flow through `dragState.draggedTabId` so @Observable per-property
    /// tracking still applies to whoever calls the binding's get.
    var draggedTabIdBinding: Binding<UUID?> {
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
    var dropIndicatorBinding: Binding<SidebarDropIndicator?> {
        Binding(
            get: { dragState.dropIndicator },
            set: { dragState.setDropIndicator($0) }
        )
    }

    /// Computed in the parent so `SidebarEmptyArea` can render its top-edge
    /// indicator from a value snapshot without holding a `SidebarDragState`
    /// reference (snapshot-boundary rule). Delegates to a pure predicate so
    /// the logic is unit-testable in isolation from view state.
    func emptyAreaTopDropIndicatorVisible() -> Bool {
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
    func emptyAreaTabDropDelegate() -> SidebarTabDropDelegate {
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

    var sidebarTopScrimHeight: CGFloat {
        SidebarWorkspaceListMetrics.topScrimHeight
    }

    var sidebarBottomScrimHeight: CGFloat {
        SidebarWorkspaceListMetrics.bottomScrimHeight
    }

    var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var titlebarDebugChromeSnapshot: MinimalModeTitlebarDebugSnapshot {
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

    var minimalModeSidebarTitlebarControlsTopPadding: CGFloat {
        guard let observedWindow else {
            return MinimalModeSidebarTitlebarControlsMetrics.topInset
        }
        return minimalModeSidebarTitlebarControlsTopInset(in: observedWindow)
    }

    private var showsSidebarNotificationMessage: Bool {
        tabItemSettingsStore.snapshot.showsNotificationMessage
    }

    var workspaceNumberShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber)
    }

    private func requestSelectedWorkspaceScroll(
        _ proxy: ScrollViewProxy,
        renderContext: WorkspaceListRenderContext
    ) {
        guard let selectedWorkspaceId = tabManager.selectedTabId,
              renderContext.workspaceIds.contains(selectedWorkspaceId) else {
            pendingSelectedWorkspaceScrollId = nil
            return
        }

        pendingSelectedWorkspaceScrollId = selectedWorkspaceId
        flushPendingSelectedWorkspaceScroll(proxy, renderContext: renderContext)
    }

    private func flushPendingSelectedWorkspaceScroll(
        _ proxy: ScrollViewProxy,
        renderContext: WorkspaceListRenderContext
    ) {
        guard let selectedWorkspaceId = pendingSelectedWorkspaceScrollId else { return }

        // Scroll unconditionally: ScrollViewProxy resolves `.id(_:)` values in
        // lazy containers without requiring the row to be realized, and an
        // unknown id is a harmless no-op. The previous design gated this on a
        // per-row "laid-out row ids" PreferenceKey whose sidebar-wide reduce
        // fed `@State` writes from inside the layout/preference update cycle,
        // the cmux-owned edge in the sidebar layout livelock
        // (https://github.com/manaflow-ai/cmux/issues/2586). No anchor means
        // SwiftUI scrolls the minimum needed to reveal the row.
        let group = renderContext.workspaceById[selectedWorkspaceId]?.groupId
            .flatMap { renderContext.workspaceGroupById[$0] }
        proxy.scrollTo(SidebarSelectedWorkspaceScrollPolicy.scrollTargetWorkspaceId(
            selectedWorkspaceId: selectedWorkspaceId,
            group: group
        ))
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

    func workspaceScrollArea(renderContext: WorkspaceListRenderContext) -> some View {
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
                    requestSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
                }
                .onChange(of: tabManager.selectedTabId) { _, _ in
                    requestSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
                }
                .onChange(of: renderContext.workspaceIds) { oldWorkspaceIds, newWorkspaceIds in
                    guard shouldRequestSelectedWorkspaceScrollAfterWorkspaceIdsChange(
                        from: oldWorkspaceIds,
                        to: newWorkspaceIds
                    ) else {
                        flushPendingSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
                        return
                    }
                    requestSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
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
            }
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

        row
            .sidebarWorkspaceFrameAnchor(id: tab.id, isEnabled: shouldCollectWorkspaceDropTargets)
            .padding(.leading, tab.groupId != nil ? SidebarWorkspaceGroupingMetrics.memberIndent : 0)
    }

    func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}
