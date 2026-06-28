import Foundation
import CoreGraphics
import Bonsplit
import CmuxWindowing
import CmuxWorkspaces

/// Resolves the tmux-style pane overlay rectangles (unread dots and the
/// attention flash) for a workspace by combining the app's `Workspace` and
/// notification unread state with the pure Bonsplit placement math in
/// ``TmuxPaneOverlayGeometry``.
///
/// This replaces a cluster of `static` methods that previously lived on
/// `WorkspaceContentView`, turning a static-method-on-View namespace into a
/// real value type. The titlebar-chrome inset is captured at construction so
/// every call site shares the same geometry; the unread/flash predicates stay
/// app-side because they read `@MainActor` `Workspace` and
/// `TerminalNotificationStore` state.
@MainActor
struct WorkspacePaneOverlayRectResolver {
    /// Pure pane-overlay placement geometry trimmed to the titlebar chrome.
    let geometry: TmuxPaneOverlayGeometry

    /// Creates a resolver.
    /// - Parameter geometry: pane-overlay placement geometry; defaults to the
    ///   minimal-mode titlebar chrome inset used across the app.
    init(
        geometry: TmuxPaneOverlayGeometry = TmuxPaneOverlayGeometry(
            topChromeHeight: MinimalModeChromeMetrics.titlebarHeight
        )
    ) {
        self.geometry = geometry
    }

    /// Resolves the trimmed content rectangles for every unread pane in a layout
    /// snapshot.
    /// - Parameters:
    ///   - workspace: the workspace whose pane unread state is read.
    ///   - notificationStore: the notification store backing the unread predicate.
    ///   - layoutSnapshot: the Bonsplit layout snapshot, if any.
    ///   - includeContainerOffset: when `true` only the container y-offset is
    ///     removed (window-content space); when `false` both axes are offset by the
    ///     container origin (workspace-local space).
    /// - Returns: one trimmed content rect per unread pane.
    private func paneRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?,
        includeContainerOffset: Bool
    ) -> [CGRect] {
        guard let layoutSnapshot else { return [] }
        let geometry = geometry
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()

        return layoutSnapshot.panes.compactMap { pane in
            guard let selectedTabId = pane.selectedTabId,
                  let tabUUID = UUID(uuidString: selectedTabId),
                  let panelId = workspace.panelIdFromSurfaceId(TabID(uuid: tabUUID)) else {
                return nil
            }

            let shouldShowUnread = Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                    forTabId: workspace.id,
                    surfaceId: panelId
                ),
                hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(panelId) ||
                    workspace.restoredUnreadPanelIds.contains(panelId),
                isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == panelId
            )
            guard shouldShowUnread else { return nil }

            let paneRect = pane.frame.cgRect
            let rect: CGRect
            if includeContainerOffset {
                rect = paneRect.offsetBy(
                    dx: 0,
                    dy: -CGFloat(layoutSnapshot.containerFrame.y)
                )
            } else {
                rect = paneRect.offsetBy(
                    dx: -CGFloat(layoutSnapshot.containerFrame.x),
                    dy: -CGFloat(layoutSnapshot.containerFrame.y)
                )
            }
            return geometry.contentRect(rect)
        }
    }

    /// Resolves a pane's overlay rect in workspace-local coordinates.
    /// - Parameters:
    ///   - layoutSnapshot: the Bonsplit layout snapshot, if any.
    ///   - paneId: the pane to resolve, if any.
    /// - Returns: the workspace-local content rect, or `nil` when unresolved.
    func paneOverlayRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        geometry.overlayRect(
            layoutSnapshot: layoutSnapshot,
            paneId: paneId
        )
    }

    /// Resolves a pane's overlay rect in window-content coordinates.
    /// - Parameters:
    ///   - layoutSnapshot: the Bonsplit layout snapshot, if any.
    ///   - paneId: the pane to resolve, if any.
    /// - Returns: the window-content content rect, or `nil` when unresolved.
    func paneWindowOverlayRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        geometry.windowOverlayRect(
            layoutSnapshot: layoutSnapshot,
            paneId: paneId
        )
    }

    /// Picks the snapshot with renderable geometry, preferring the live snapshot.
    /// - Parameters:
    ///   - cachedSnapshot: the previously cached snapshot, if any.
    ///   - liveSnapshot: the freshly read live snapshot, if any.
    /// - Returns: the effective snapshot to render with.
    func effectiveLayoutSnapshot(
        cachedSnapshot: LayoutSnapshot?,
        liveSnapshot: LayoutSnapshot?
    ) -> LayoutSnapshot? {
        geometry.effectiveSnapshot(
            cachedSnapshot: cachedSnapshot,
            liveSnapshot: liveSnapshot
        )
    }

    /// Resolves unread pane content rects in workspace-local coordinates.
    /// - Parameters:
    ///   - workspace: the workspace whose pane unread state is read.
    ///   - notificationStore: the notification store backing the unread predicate.
    ///   - layoutSnapshot: the Bonsplit layout snapshot, if any.
    /// - Returns: one workspace-local content rect per unread pane.
    func paneUnreadRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?
    ) -> [CGRect] {
        paneRects(
            workspace: workspace,
            notificationStore: notificationStore,
            layoutSnapshot: layoutSnapshot,
            includeContainerOffset: false
        )
    }

    /// Resolves unread pane content rects in window-content coordinates.
    /// - Parameters:
    ///   - workspace: the workspace whose pane unread state is read.
    ///   - notificationStore: the notification store backing the unread predicate.
    ///   - layoutSnapshot: the Bonsplit layout snapshot, if any.
    /// - Returns: one window-content content rect per unread pane.
    func paneWindowUnreadRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?
    ) -> [CGRect] {
        paneRects(
            workspace: workspace,
            notificationStore: notificationStore,
            layoutSnapshot: layoutSnapshot,
            includeContainerOffset: true
        )
    }
}
