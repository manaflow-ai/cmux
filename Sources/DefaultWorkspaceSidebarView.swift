import AppKit
import Bonsplit
import Combine
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxSidebar
import CmuxWorkspaces
import SwiftUI

/// The independently diffed default workspace area of the vertical sidebar.
///
/// This view owns the broad `TabManager`, `CmuxConfigStore`, and live
/// `Workspace` reads needed to build the list. It converts them to immutable
/// row inputs and action bundles before crossing the lazy-list boundary, so
/// realized rows do not retain those broad stores.
struct DefaultWorkspaceSidebarView: View, Equatable {
    static let workspaceObservationCoalesceInterval: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(40)

    let renderContext: WorkspaceListRenderContext
    let isPresented: Bool
    let usesAppKitSidebarList: Bool
    let sidebarUnread: SidebarUnreadModel
    let titlebarControlsLayoutModel: TitlebarControlsLayoutModel
    let windowId: UUID
    let observedWindowReference: WeakWindowReference
    let modifierKeyMonitor: WindowScopedShortcutHintModifierMonitor
    let pointerInteractionMonitor: SidebarPointerInteractionMonitor
    let dragAutoScrollController: SidebarDragAutoScrollController
    let dragState: SidebarDragState
    let showModifierHoldHints: Bool
    let titlebarDebugChromeSnapshot: MinimalModeTitlebarDebugSnapshot
    let onToggleSidebar: () -> Void
    let onNewTab: () -> Void
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let tabManager: TabManager
    let cmuxConfigStore: CmuxConfigStore
#if DEBUG
    @Environment(\.sidebarLazyContractProbe) var sidebarLazyContractProbe
#endif
    @State var owner = DefaultWorkspaceSidebarOwner()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.renderContext.identity == rhs.renderContext.identity
            && lhs.tabManager === rhs.tabManager
            && lhs.cmuxConfigStore === rhs.cmuxConfigStore
            && lhs.isPresented == rhs.isPresented
            && lhs.usesAppKitSidebarList == rhs.usesAppKitSidebarList
            && lhs.sidebarUnread === rhs.sidebarUnread
            && lhs.titlebarControlsLayoutModel === rhs.titlebarControlsLayoutModel
            && lhs.windowId == rhs.windowId
            && lhs.observedWindowReference.window === rhs.observedWindowReference.window
            && lhs.modifierKeyMonitor === rhs.modifierKeyMonitor
            && lhs.pointerInteractionMonitor === rhs.pointerInteractionMonitor
            && lhs.dragAutoScrollController === rhs.dragAutoScrollController
            && lhs.dragState === rhs.dragState
            && lhs.showModifierHoldHints == rhs.showModifierHoldHints
            && lhs.titlebarDebugChromeSnapshot == rhs.titlebarDebugChromeSnapshot
    }

    var body: some View {
#if DEBUG
        let _ = { sidebarLazyContractProbe.defaultWorkspaceAreaBody?() }()
#endif
        workspaceScrollArea(renderContext: renderContext)
            .onAppear {
                owner.isBonsplitWorkspaceDropTargetCollectionActive = false
                owner.isWorkspaceReorderDropTargetCollectionActive = false
            }
            .onDisappear {
                owner.resetPresentationState()
            }
            .onChange(of: showModifierHoldHints) { _, enabled in
                guard !enabled else { return }
                owner.frozenShortcutHintsTabId = nil
                owner.frozenShortcutHintsValue = false
            }
            .onChange(of: renderContext.tabIds) { _, tabIds in
                guard let frozenTabId = owner.frozenShortcutHintsTabId,
                      !tabIds.contains(frozenTabId) else { return }
                owner.frozenShortcutHintsTabId = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .workspaceChecklistAddItemRequested)) { notification in
                guard isPresented else { return }
                guard let workspaceId = notification.userInfo?[WorkspaceTodoActions.workspaceIdUserInfoKey] as? UUID,
                      tabManager.tabs.contains(where: { $0.id == workspaceId }) else { return }
                if WorkspaceTodoFeature.checklistStyle == .popover {
                    owner.checklistPopoverWorkspaceId = workspaceId
                } else {
                    owner.expandedChecklistWorkspaceIds.insert(workspaceId)
                }
                owner.checklistAddFieldActivationTokens[workspaceId, default: 0] += 1
            }
    }

    var observedWindow: NSWindow? { observedWindowReference.window }
    var notificationStore: TerminalNotificationStore { .shared }
    var tabRowSpacing: CGFloat { 2 }
    var sidebarTopScrimHeight: CGFloat { SidebarWorkspaceListMetrics.topScrimHeight }
    var sidebarBottomScrimHeight: CGFloat { SidebarWorkspaceListMetrics.bottomScrimHeight }
    var sidebarTitlebarInteractionHeight: CGFloat { MinimalModeChromeMetrics.titlebarHeight }

    var minimalModeSidebarTitlebarControlsTopPadding: CGFloat {
        guard let observedWindow else {
            return MinimalModeSidebarTitlebarControlsMetrics.topInset
        }
        return minimalModeSidebarTitlebarControlsTopInset(in: observedWindow)
    }

    func minimalModeSidebarTitlebarControlsOverlay() -> some View {
        MinimalModeSidebarTitlebarControlsOverlay(
            unreadModel: sidebarUnread,
            layoutModel: titlebarControlsLayoutModel,
            leadingInset: CGFloat(titlebarDebugChromeSnapshot.leftControlsLeadingInset),
            topPadding: minimalModeSidebarTitlebarControlsTopPadding,
            onToggleSidebar: onToggleSidebar,
            onToggleNotifications: { anchorView in
                AppDelegate.shared?.toggleNotificationsPopover(
                    animated: true,
                    anchorView: anchorView
                )
            },
            onNewTab: onNewTab,
            onFocusHistoryBack: {
                if !tabManager.navigateBack() { NSSound.beep() }
            },
            onFocusHistoryForward: {
                if !tabManager.navigateForward() { NSSound.beep() }
            }
        )
    }

    var draggedTabIdBinding: Binding<UUID?> {
        Binding(
            get: { dragState.draggedTabId },
            set: { newValue in
                if let newValue {
                    dragState.draggedTabId = newValue
                } else {
                    dragState.clearDrag()
                }
            }
        )
    }

    var dropIndicatorBinding: Binding<SidebarDropIndicator?> {
        Binding(
            get: { dragState.dropIndicator },
            set: { dragState.setDropIndicator($0) }
        )
    }

    func emptyAreaTopDropIndicatorVisible() -> Bool {
        let reorderIds = tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            usesTopLevelRows: dragState.dropIndicatorUsesTopLevelRows
        )
        return SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            lastTabId: reorderIds.last,
            indicatorScope: dragState.dropIndicatorScope
        )
    }

    func emptyAreaTabDropDelegate(renderContext: WorkspaceListRenderContext) -> SidebarTabDropDelegate {
        SidebarTabDropDelegate(
            targetTabId: nil,
            tabManager: tabManager,
            workspaceGroupIdByWorkspaceId: renderContext.workspaceGroupIdByWorkspaceId,
            dragState: dragState,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            targetRowHeight: nil,
            dragAutoScrollController: dragAutoScrollController
        )
    }

    func sidebarDropIndicatorRowIds(
        draggedWorkspaceId: UUID,
        scope: SidebarWorkspaceReorderDropIndicatorScope,
        tabs: [Workspace],
        workspaceGroups: [WorkspaceGroup],
        visibleWorkspaceRowIds: [UUID]
    ) -> [UUID] {
        switch scope {
        case .raw:
            return tabs.map(\.id)
        case .topLevel:
            return tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedWorkspaceId,
                usesTopLevelRows: true
            )
        case .group(let groupId):
            guard workspaceGroups.contains(where: { $0.id == groupId }) else { return [] }
            let visibleIds = Set(visibleWorkspaceRowIds)
            return tabs.filter { $0.groupId == groupId && visibleIds.contains($0.id) }.map(\.id)
        }
    }

    var isBonsplitWorkspaceDropTargetCollectionActive: Bool {
        get { owner.isBonsplitWorkspaceDropTargetCollectionActive }
        nonmutating set { owner.isBonsplitWorkspaceDropTargetCollectionActive = newValue }
    }
    var isWorkspaceReorderDropTargetCollectionActive: Bool {
        get { owner.isWorkspaceReorderDropTargetCollectionActive }
        nonmutating set { owner.isWorkspaceReorderDropTargetCollectionActive = newValue }
    }
    var frozenShortcutHintsTabId: UUID? {
        get { owner.frozenShortcutHintsTabId }
        nonmutating set { owner.frozenShortcutHintsTabId = newValue }
    }
    var frozenShortcutHintsValue: Bool {
        get { owner.frozenShortcutHintsValue }
        nonmutating set { owner.frozenShortcutHintsValue = newValue }
    }
    var pendingSelectedWorkspaceScrollId: UUID? {
        get { owner.pendingSelectedWorkspaceScrollId }
        nonmutating set { owner.pendingSelectedWorkspaceScrollId = newValue }
    }
    var expandedChecklistWorkspaceIds: Set<UUID> {
        get { owner.expandedChecklistWorkspaceIds }
        nonmutating set { owner.expandedChecklistWorkspaceIds = newValue }
    }
    var expandedMetadataWorkspaceIds: Set<UUID> {
        get { owner.expandedMetadataWorkspaceIds }
        nonmutating set { owner.expandedMetadataWorkspaceIds = newValue }
    }
    var expandedMarkdownWorkspaceIds: Set<UUID> {
        get { owner.expandedMarkdownWorkspaceIds }
        nonmutating set { owner.expandedMarkdownWorkspaceIds = newValue }
    }
    var checklistAddFieldActivationTokens: [UUID: Int] {
        get { owner.checklistAddFieldActivationTokens }
        nonmutating set { owner.checklistAddFieldActivationTokens = newValue }
    }
    var editingChecklistItemIds: [UUID: UUID] {
        get { owner.editingChecklistItemIds }
        nonmutating set { owner.editingChecklistItemIds = newValue }
    }
    var bonsplitWorkspaceDropTargetBridge: SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge {
        owner.bonsplitWorkspaceDropTargetBridge
    }
    var workspaceReorderDropTargetBridge: SidebarWorkspaceReorderDropOverlay.TargetBridge {
        owner.workspaceReorderDropTargetBridge
    }
    var appKitRowSnapshotCache: SidebarRowSnapshotCache { owner.appKitRowSnapshotCache }
    var appKitFrozenTableRowsBox: SidebarAppKitFrozenRowsBox { owner.appKitFrozenTableRowsBox }
    var appKitPostResizeRefreshToken: UInt64 {
        get { owner.appKitPostResizeRefreshToken }
        nonmutating set { owner.appKitPostResizeRefreshToken = newValue }
    }
    var checklistPopoverWorkspaceId: UUID? {
        get { owner.checklistPopoverWorkspaceId }
        nonmutating set { owner.checklistPopoverWorkspaceId = newValue }
    }
    var workspaceSnapshotsById: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot] {
        get { owner.workspaceSnapshotsById }
        nonmutating set { owner.workspaceSnapshotsById = newValue }
    }
    var anchorCwdRevision: Int {
        get { owner.anchorCwdRevision }
        nonmutating set { owner.anchorCwdRevision = newValue }
    }
}
