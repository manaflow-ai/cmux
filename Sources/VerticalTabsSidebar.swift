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
    @StateObject var tabItemSettingsStore = SidebarTabItemSettingsStore(
        initialSidebarFontSize: GhosttyConfig.load().sidebarFontSize
    )
    @ObservedObject var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State var dragState = SidebarDragState()
    // Bonsplit tab drags arrive through AppKit pasteboard callbacks, not
    // `SidebarDragState`, so they need a separate transient collection flag.
    @State var isBonsplitWorkspaceDropTargetCollectionActive = false
    @State var bonsplitWorkspaceDropTargetBridge = SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge()
    // Freezes `showsModifierShortcutHints` for the workspace whose context menu
    // is open. Set on the row's contextMenu.onAppear and cleared on
    // .onDisappear so modifier-key transitions don't flip the badges on the
    // row sitting behind the open menu. See `SidebarShortcutHintFreezePolicy`.
    @State var frozenShortcutHintsTabId: UUID?
    @State var frozenShortcutHintsValue: Bool = false
    @State var pendingSelectedWorkspaceScrollId: UUID?
    @State var collapsedExtensionSidebarSectionIds: Set<String> = []
    @State var extensionSidebarWorktreeCreationInFlightSectionIds: Set<String> = []
    @State var extensionSidebarUpdateToken: UInt64 = 0
    /// Bumped whenever any workspace's currentDirectory changes; the group
    /// header's resolved cwd-based config (color/icon/context menu /
    /// newWorkspacePlacement) reads it through the body, so a state
    /// invalidation here forces SwiftUI to re-call
    /// `cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd:)`. The anchor
    /// has no TabItemView, so no implicit per-row publisher subscription
    /// would otherwise fire on `cd` while it's not selected.
    @State var anchorCwdRevision: Int = 0
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(CmuxExtensionSidebarSelection.defaultsKey)
    var selectedExtensionSidebarProviderId = CmuxExtensionSidebarSelection.defaultProviderId
    @LiveSetting(\.betaFeatures.extensions) var extensionsExperimentalEnabled
    @LiveSetting(\.betaFeatures.customSidebars) var customSidebarsExperimentalEnabled

    @AppStorage("sidebarMatchTerminalBackground")
    var sidebarMatchTerminalBackground = false
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
    var titlebarLeftControlsLeadingInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey)
    var titlebarLeftControlsTopInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset

    let tabRowSpacing: CGFloat = 2
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

}

