public import Foundation
public import Bonsplit
#if DEBUG
import CMUXDebugLog
#endif

/// Drives a workspace's surface move/reorder commands against the live split
/// tree: moving a surface into a target pane, moving a surface to the adjacent
/// pane in a direction, reordering a surface within its pane, and realigning the
/// remote-tmux mirror tabs to a tmux window order.
///
/// These commands are lifted one-for-one from the legacy `Workspace`
/// Panel-Operations bodies (`moveSurface(panelId:toPane:atIndex:focus:)`,
/// `moveSurfaceToAdjacentPane(panelId:direction:)`,
/// `reorderSurface(panelId:toIndex:focus:)`,
/// `reorderRemoteTmuxMirrorTabs(toPanelOrder:)`). Every split-tree mutation and
/// every workspace-side focus/selection/geometry side effect is reached through
/// ``SplitMoveReorderHosting`` so this type never holds the app-target
/// `Workspace`, while the state it mutates and the reconcilers it triggers are
/// always the live ones. The mirror-tab order computation
/// (`RemoteTmuxSessionMirror.mirrorTabReorder`) stays app-side and is reached
/// through the host so the package does not depend on the app's tmux types.
@MainActor
public final class SplitMoveReorderCoordinator {
    private weak var host: (any SplitMoveReorderHosting)?

    /// Creates the coordinator. Call ``attach(host:)`` before use.
    public init() {}

    /// Attaches the workspace-side host the commands drive through.
    public func attach(host: any SplitMoveReorderHosting) {
        self.host = host
    }

    /// Moves a surface into the target pane (optionally at an index), focusing
    /// it by default; returns whether the move took. Lifted one-for-one from
    /// `Workspace.moveSurface`.
    @discardableResult
    public func moveSurface(panelId: UUID, toPane paneId: PaneID, atIndex index: Int? = nil, focus: Bool = true) -> Bool {
        guard let host else { return false }
        guard let tabId = host.surfaceId(forPanelId: panelId) else { return false }
        guard host.allBonsplitPaneIds.contains(paneId) else { return false }
        guard host.moveTab(tabId, toPane: paneId, atIndex: index) else { return false }

        if focus {
            host.focusPane(paneId)
            host.selectTab(tabId)
            host.focusPanel(panelId)
        } else {
            host.scheduleFocusReconcile()
        }
        host.scheduleTerminalGeometryReconcile()
        return true
    }

    /// Moves a surface to the pane adjacent to its current pane in the given
    /// direction, focusing it; returns whether the move took. Lifted one-for-one
    /// from `Workspace.moveSurfaceToAdjacentPane`.
    @discardableResult
    public func moveSurfaceToAdjacentPane(panelId: UUID, direction: NavigationDirection) -> Bool {
        guard let host else { return false }
        guard host.hasPanel(panelId),
              let sourcePaneId = host.paneId(forPanelId: panelId),
              let targetPaneId = host.adjacentPane(to: sourcePaneId, direction: direction) else {
            return false
        }
        return moveSurface(panelId: panelId, toPane: targetPaneId, focus: true)
    }

    /// Reorders a surface to the given index within its pane, applying tab
    /// selection by default; returns whether the reorder took. Lifted
    /// one-for-one from `Workspace.reorderSurface`.
    @discardableResult
    public func reorderSurface(panelId: UUID, toIndex index: Int, focus: Bool = true) -> Bool {
        guard let host else { return false }
        guard let tabId = host.surfaceId(forPanelId: panelId) else { return false }
        guard host.reorderTab(tabId, toIndex: index) else { return false }

        if focus, let paneId = host.paneId(forPanelId: panelId) {
            host.applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            host.scheduleFocusReconcile()
        }
        host.scheduleTerminalGeometryReconcile()
        return true
    }

    /// Reorders this workspace's remote-tmux mirror tabs so their left-to-right
    /// order matches `panelOrder` (the tmux window order), preserving the user's
    /// current tab selection and pane focus.
    ///
    /// This follows reorders that originate on the remote (a second tmux client, or
    /// a manual `move-window` / a `new-window` inserted mid-list). The cmux→tmux
    /// drag direction is handled by `handleMirrorWindowsReordered`. bonsplit's
    /// `reorderTab` selects+focuses the moved tab (and `selectTab`/`focusPane` fire
    /// the same activation), so the whole operation runs under
    /// ``SplitMoveReorderHosting/setApplyingRemoteTmuxTabReorder(_:)`` to suppress
    /// that churn — a reactive tmux event must not steal focus or resume agents
    /// (socket focus policy). The user's selection/focus are unchanged, so
    /// bonsplit's internal state is just restored to match. No-ops when the tabs
    /// already match or aren't all in one pane.
    ///
    /// Known beta limitation: if a *remote* window reorder arrives while the user is
    /// mid tab-drag, this can move tabs under the drag. The trigger is narrow (a
    /// concurrent remote reorder during a ~1s local drag) and self-heals — the
    /// drop's `didReorderTabsInPane` reconciles `connection.windowOrder` to the
    /// final order. A drag-aware guard would need bonsplit to expose drag state.
    @discardableResult
    public func reorderRemoteTmuxMirrorTabs(toPanelOrder panelOrder: [UUID]) -> Bool {
        guard let host else { return false }
        // All mirror tabs must live in a single pane: a global tmux window order
        // can't be expressed across a user-arranged split. If the requested panels
        // resolve to more than one pane (or none), skip rather than reorder a
        // subset of one pane.
        let presentPaneIds = Set(panelOrder.compactMap { host.paneId(forPanelId: $0) })
        guard presentPaneIds.count == 1, let paneId = presentPaneIds.first else { return false }
        let currentPanelIds = host.tabs(inPane: paneId).compactMap { host.panelId(forSurfaceId: $0.id) }
        guard let desired = host.mirrorTabReorder(current: currentPanelIds, requested: panelOrder) else { return false }
#if DEBUG
        CMUXDebugLog.logDebugEvent("remote-tmux: reorder mirror tabs ws=\(host.workspaceId.uuidString.prefix(5)) count=\(desired.count)")
#endif

        let savedSelectedTabId = host.selectedTab(inPane: paneId)?.id
        let savedFocusedPaneId = host.focusedBonsplitPaneId

        host.setApplyingRemoteTmuxTabReorder(true)
        defer { host.setApplyingRemoteTmuxTabReorder(false) }
        for (index, panelId) in desired.enumerated() {
            guard let tabId = host.surfaceId(forPanelId: panelId) else { continue }
            _ = host.reorderTab(tabId, toIndex: index)
        }
        // Restore bonsplit's internal selection + focus (the loop moved them to the
        // last-reordered tab). cmux's own focus/selection were never touched (the
        // delegate handlers short-circuited), so this just realigns bonsplit with
        // the user's unchanged state — no `applyTabSelection` runs.
        if let savedSelectedTabId { host.selectTab(savedSelectedTabId) }
        if let savedFocusedPaneId { host.focusPane(savedFocusedPaneId) }

        host.scheduleTerminalGeometryReconcile()
        return true
    }
}
