import AppKit
import Bonsplit
import CmuxNotifications

/// Builds the window's workspace pane overlay (the tmux-style unread rings,
/// the attention flash and the active pane border) from the selected
/// workspace, in the coordinate space of the overlay's canvas.
///
/// ``TmuxWorkspacePaneOverlayRefresher`` calls ``refresh(in:)`` from
/// `updateNSView`, where SwiftUI tracks every Observation read the build
/// makes, so the overlay rebuilds when the selection, bonsplit geometry,
/// focus, unread state or experiment target change. The inputs that aren't
/// observable live in ``Settings`` and reach the refresher through its
/// equality. `ContentView` calls the same methods for the triggers that
/// aren't observable either: focus notifications, geometry callbacks, layout
/// mode changes and glass root swaps.
@MainActor
struct TmuxWorkspacePaneOverlayStateBuilder {
    let tabManager: TabManager
    let sidebarUnread: SidebarUnreadModel
    let experiment: TmuxOverlayExperimentTargetObserver
    let notificationStore: TerminalNotificationStore
    let settings: TmuxWorkspacePaneOverlaySettings

    /// Builds the overlay for `window` and hands it to the window's overlay
    /// controller, which skips a state equal to the one it last rendered.
    func refresh(in window: NSWindow?) {
        guard let window else { return }
        let state = state(for: window)
        WindowTmuxWorkspacePaneOverlayController.controller(
            for: window,
            createIfNeeded: state != nil
        )?.update(state: state)
    }

    /// Coalesces geometry-driven rebuilds into one per main-actor turn while
    /// the overlay is shown or may need to be.
    func scheduleGeometryRefresh(in window: NSWindow?) {
        guard let window,
              shouldScheduleGeometryRefresh(in: window),
              let controller = WindowTmuxWorkspacePaneOverlayController.controller(
                  for: window,
                  createIfNeeded: true
              ) else { return }
        controller.scheduleGeometryRefresh { [weak window] in
            guard let window else { return nil }
            return state(for: window)
        }
    }

    private func shouldScheduleGeometryRefresh(in window: NSWindow) -> Bool {
        if experiment.target.usesWorkspacePaneOverlay { return true }
        if WindowTmuxWorkspacePaneOverlayController.controller(
            for: window,
            createIfNeeded: false
        )?.hasRenderedState == true { return true }
        guard let workspace = tabManager.selectedWorkspace else { return false }
        return shouldShowActivePaneBorder(for: workspace)
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
