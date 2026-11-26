import AppKit
import Bonsplit
import CmuxNotifications

/// Builds the window's workspace pane overlay (the tmux-style unread rings,
/// the attention flash and the active pane border) from the selected
/// workspace, in the coordinate space of the overlay's canvas.
///
/// The SwiftUI leaf reads ``inputs`` to establish all model dependencies.
/// The coordinator compares those inputs and AppKit geometry before calling
/// ``state(for:)``; this type owns projection, not refresh scheduling.
@MainActor
struct TmuxWorkspacePaneOverlayStateBuilder {
    let tabManager: TabManager
    let sidebarUnread: SidebarUnreadModel
    let experiment: TmuxOverlayExperimentTargetObserver
    let notificationStore: TerminalNotificationStore
    let settings: TmuxWorkspacePaneOverlaySettings

    /// Captures render dependencies without defaults I/O or AppKit mutation.
    var inputs: TmuxWorkspacePaneOverlayInputs {
        var result = TmuxWorkspacePaneOverlayInputs(target: experiment.target, settings: settings)
        guard let workspace = tabManager.selectedWorkspace else { return result }
        result.workspaceId = workspace.id
        result.workspaceIdentity = ObjectIdentifier(workspace)
        result.isCanvas = workspace.layoutMode == .canvas
        result.selectionRevision = workspace.tmuxOverlaySelectionRevision
        guard result.target.usesWorkspacePaneOverlay || shouldShowActivePaneBorder(for: workspace) else {
            return result
        }
        // Do not call Bonsplit's live layout snapshot from the SwiftUI input
        // read. That walks every pane's tabs and would subscribe this leaf to
        // title animation updates. Geometry callbacks refresh this cached
        // snapshot before an admitted render.
        let layout = workspace.tmuxLayoutSnapshot
        // Snapshot timestamps are sampling metadata, not rendering inputs.
        result.layout = layout.map {
            LayoutSnapshot(containerFrame: $0.containerFrame, panes: $0.panes,
                           focusedPaneId: $0.focusedPaneId, timestamp: 0)
        }
        result.isZoomed = workspace.bonsplitController.isSplitZoomed
        if let focusedPaneId = layout?.focusedPaneId,
           let focusedPane = layout?.panes.first(where: { $0.paneId == focusedPaneId }),
           let selected = focusedPane.selectedTabId.flatMap(UUID.init(uuidString:)) {
            result.focusedPanelId = workspace.panelIdFromSurfaceId(TabID(uuid: selected))
        }
        result.flashPanelId = workspace.tmuxWorkspaceFlashPanelId
        result.flashToken = workspace.tmuxWorkspaceFlashToken
        result.flashReason = workspace.tmuxWorkspaceFlashReason
        var visiblePanelIds = Set(layout?.panes.compactMap { pane -> UUID? in
            guard let tab = pane.selectedTabId.flatMap(UUID.init(uuidString:)) else { return nil }
            return workspace.panelIdFromSurfaceId(TabID(uuid: tab))
        } ?? [])
        if let id = result.focusedPanelId { visiblePanelIds.insert(id) }
        if let id = result.flashPanelId { visiblePanelIds.insert(id) }
        for id in visiblePanelIds {
            if let panel = workspace.panels[id] { result.panelIdentities[id] = ObjectIdentifier(panel) }
        }
        if result.target.usesWorkspacePaneOverlay {
            let unread = sidebarUnread.snapshot
            result.unreadPanelIds = workspace.manualUnreadPanelIds.union(workspace.restoredUnreadPanelIds)
            result.notificationPanelIds = Set(visiblePanelIds.filter {
                unread.hasVisibleNotificationIndicator(forWorkspaceId: workspace.id, surfaceId: $0)
            })
            result.isWorkspaceManuallyUnread = unread.hasManualUnread(forWorkspaceId: workspace.id)
            result.manualUnreadRepresentative = workspace.representativePanelIdForWorkspaceManualUnread()
        }
        return result
    }

    private func shouldShowActivePaneBorder(for workspace: Workspace) -> Bool {
        settings.activePaneBorderColorHex != nil
            && workspace.layoutMode != .canvas
            && !settings.rightSidebarOwnsInputFocus
            && workspace.bonsplitController.allPaneIds.count > 1
    }

    /// The overlay for the selected workspace, or `nil` when neither the
    /// workspace pane experiment nor the active pane border applies.
    func state(for window: NSWindow) -> TmuxWorkspacePaneOverlayRenderState? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        let usesWorkspacePaneOverlay = experiment.target.usesWorkspacePaneOverlay
        let shouldShowActivePaneBorder = shouldShowActivePaneBorder(for: workspace)
        guard usesWorkspacePaneOverlay || shouldShowActivePaneBorder else { return nil }

        let layoutSnapshot = WorkspaceContentView.effectiveTmuxLayoutSnapshot(
            cachedSnapshot: workspace.tmuxLayoutSnapshot,
            liveSnapshot: workspace.bonsplitController.layoutSnapshot()
        )
        let contentView = WindowTmuxWorkspacePaneOverlayController.controller(
            for: window,
            createIfNeeded: true
        )?.coordinateReferenceView ?? window.contentView

        let unreadRects = usesWorkspacePaneOverlay
            ? unreadRects(for: workspace, layoutSnapshot: layoutSnapshot, contentView: contentView)
            : []
        let flashRect = usesWorkspacePaneOverlay
            ? flashRect(for: workspace, layoutSnapshot: layoutSnapshot, contentView: contentView)
            : nil
        let activePaneBorderRect = shouldShowActivePaneBorder
            ? activePaneBorderRect(for: workspace, layoutSnapshot: layoutSnapshot, contentView: contentView)
            : nil

        if unreadRects.isEmpty, flashRect == nil, activePaneBorderRect == nil, !usesWorkspacePaneOverlay {
            return nil
        }
        return TmuxWorkspacePaneOverlayRenderState(
            workspaceId: workspace.id,
            unreadRects: unreadRects,
            flashRect: flashRect,
            activePaneBorderRect: activePaneBorderRect,
            activePaneBorderColorHex: activePaneBorderRect == nil ? nil : settings.activePaneBorderColorHex,
            flashToken: workspace.tmuxWorkspaceFlashToken,
            flashReason: workspace.tmuxWorkspaceFlashReason,
            workspaceAttentionColor: settings.workspaceAttentionColor
        )
    }

    private func unreadRects(
        for workspace: Workspace,
        layoutSnapshot: LayoutSnapshot?,
        contentView: NSView?
    ) -> [CGRect] {
        // Read on both paths so an unread change rebuilds the overlay even
        // while the fallback, which reads the notification store, applies.
        let unreadSnapshot = sidebarUnread.snapshot
        guard let layoutSnapshot, let contentView else {
            return WorkspaceContentView.tmuxWorkspacePaneWindowUnreadRects(
                workspace: workspace,
                notificationStore: notificationStore,
                layoutSnapshot: layoutSnapshot
            )
        }
        let isWorkspaceManuallyUnread = unreadSnapshot.hasManualUnread(forWorkspaceId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()
        return layoutSnapshot.panes.compactMap { pane in
            guard let selectedTabId = pane.selectedTabId,
                  let tabUUID = UUID(uuidString: selectedTabId),
                  let panelId = workspace.panelIdFromSurfaceId(TabID(uuid: tabUUID)),
                  let panel = workspace.panels[panelId] else {
                return nil
            }

            let shouldShowUnread = Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: unreadSnapshot.hasVisibleNotificationIndicator(
                    forWorkspaceId: workspace.id,
                    surfaceId: panelId
                ),
                hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(panelId) ||
                    workspace.restoredUnreadPanelIds.contains(panelId),
                isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == panelId
            )
            guard shouldShowUnread else { return nil }

            let paneRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                layoutSnapshot: layoutSnapshot,
                paneId: workspace.paneId(forPanelId: panelId)
            )
            let exactRect = ContentView.tmuxWorkspacePaneExactRect(for: panel, in: contentView)
            return WorkspaceContentView.tmuxPaneOverlayGeometry.preferredWindowOverlayRect(
                exactRect: exactRect,
                paneRect: paneRect
            )
        }
    }

    private func flashRect(
        for workspace: Workspace,
        layoutSnapshot: LayoutSnapshot?,
        contentView: NSView?
    ) -> CGRect? {
        guard let panelId = workspace.tmuxWorkspaceFlashPanelId else {
            return WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                layoutSnapshot: layoutSnapshot,
                paneId: nil
            )
        }
        let paneRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
            layoutSnapshot: layoutSnapshot,
            paneId: workspace.paneId(forPanelId: panelId)
        )
        guard let panel = workspace.panels[panelId], let contentView else { return paneRect }
        let exactRect = ContentView.tmuxWorkspacePaneExactRect(for: panel, in: contentView)
        return WorkspaceContentView.tmuxPaneOverlayGeometry.preferredWindowOverlayRect(
            exactRect: exactRect,
            paneRect: paneRect
        )
    }

    private func activePaneBorderRect(
        for workspace: Workspace,
        layoutSnapshot: LayoutSnapshot?,
        contentView: NSView?
    ) -> CGRect? {
        guard let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else { return nil }
        let paneRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
            layoutSnapshot: layoutSnapshot,
            paneId: workspace.paneId(forPanelId: panelId)
        )
        let exactRect = contentView.flatMap { ContentView.tmuxWorkspacePaneExactRect(for: panel, in: $0) }
        let isSplitZoomed = workspace.bonsplitController.isSplitZoomed
        // Bonsplit's zoomed container covers the visible pane; hosted terminal
        // views can include a tab-chrome offset during the zoom transition.
        return WorkspaceContentView.tmuxPaneOverlayGeometry.preferredWindowOverlayRect(
            exactRect: exactRect,
            paneRect: paneRect,
            isSplitZoomed: isSplitZoomed,
            zoomedContainerRect: isSplitZoomed
                ? WorkspaceContentView.tmuxPaneOverlayGeometry.zoomedWindowOverlayRect(layoutSnapshot: layoutSnapshot)
                : nil
        )
    }
}
