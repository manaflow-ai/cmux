import Bonsplit
import Foundation

extension Workspace {
    @discardableResult
    func reorderSurface(panelId: UUID, toIndex index: Int, focus: Bool = true) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        let mirrorPaneId = isRemoteTmuxMirror ? paneId(forPanelId: panelId) : nil
        let reordered: Bool
        if let mirrorPaneId {
            reordered = performRemoteTmuxMirrorOrderMutation(in: mirrorPaneId) {
                bonsplitController.reorderTab(tabId, toIndex: index)
            }
        } else {
            guard !isRemoteTmuxMirror else { return false }
            reordered = bonsplitController.reorderTab(tabId, toIndex: index)
        }
        guard reordered else { return false }
        if focus, let paneId = paneId(forPanelId: panelId) {
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    /// Applies one optimistic mirror order mutation and rolls it back if tmux rejects it.
    func performRemoteTmuxMirrorOrderMutation(
        in paneId: PaneID,
        beforeRollback: () -> Void = {},
        onVerification: ((Bool) -> Void)? = nil,
        _ mutation: () -> Bool
    ) -> Bool {
        let tabs = bonsplitController.tabs(inPane: paneId)
        let previousPanelOrder = tabs.compactMap { panelIdFromSurfaceId($0.id) }
        guard previousPanelOrder.count == tabs.count, remoteTmuxWindowOrderSync != nil else { return false }
        return performRemoteTmuxMirrorMutation {
            guard mutation() else { return false }
            let desiredPanelOrder = bonsplitController.tabs(inPane: paneId).compactMap {
                panelIdFromSurfaceId($0.id)
            }
            guard desiredPanelOrder.count == tabs.count,
                  remoteTmuxWindowOrderSync?(desiredPanelOrder, onVerification) == true else {
                beforeRollback()
                _ = reorderRemoteTmuxMirrorTabs(toPanelOrder: previousPanelOrder)
                return false
            }
            return true
        }
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
    /// the shared mirror-mutation transaction to suppress that churn — a reactive
    /// tmux event must not steal focus or resume agents (socket focus policy). The
    /// user's selection/focus are restored from one snapshot after the reorder.
    /// No-ops when the tabs already match or aren't all in one pane.
    ///
    /// Known beta limitation: if a *remote* window reorder arrives while the user is
    /// mid tab-drag, this can move tabs under the drag. The trigger is narrow (a
    /// concurrent remote reorder during a ~1s local drag) and self-heals — the
    /// drop's `didReorderTabsInPane` reconciles `connection.windowOrder` to the
    /// final order. A drag-aware guard would need bonsplit to expose drag state.
    @discardableResult
    func reorderRemoteTmuxMirrorTabs(toPanelOrder panelOrder: [UUID]) -> Bool {
        // A global tmux window order cannot span multiple cmux panes.
        let presentPaneIds = Set(panelOrder.compactMap { paneId(forPanelId: $0) })
        guard presentPaneIds.count == 1, let paneId = presentPaneIds.first else { return false }
        let currentPanelIds = bonsplitController.tabs(inPane: paneId).compactMap { panelIdFromSurfaceId($0.id) }
        guard let desired = RemoteTmuxSessionMirror.mirrorTabReorder(
            current: currentPanelIds,
            requested: panelOrder
        ) else { return false }
#if DEBUG
        cmuxDebugLog("remote-tmux: reorder mirror tabs ws=\(id.uuidString.prefix(5)) count=\(desired.count)")
#endif

        performRemoteTmuxMirrorMutation {
            for (index, panelId) in desired.enumerated() {
                guard let tabId = surfaceIdFromPanelId(panelId) else { continue }
                _ = bonsplitController.reorderTab(tabId, toIndex: index)
            }
        }

        scheduleTerminalGeometryReconcile()
        return true
    }
}
