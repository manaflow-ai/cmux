import CmuxWorkspaces
import Foundation

extension Workspace {
    /// Starts title admission for a newly rebuilt terminal after persisted metadata lands.
    func armRestoredPanelTitleBoundary(panelId: UUID, internallySeededInput: String?) {
        // There is deliberately no timer fallback: elapsed time cannot prove
        // that PTY startup ended. Raw titles remain untrusted until the managed
        // shell reports activity; explicit custom-title APIs bypass this path.
        let boundary = RestoredPanelTitleBoundary(
            internallySeededInput: internallySeededInput,
            shellState: panelShellActivityStates[panelId] ?? .unknown
        )
        if boundary.isReleased {
            restoredPanelTitleBoundariesByPanelId.removeValue(forKey: panelId)
        } else {
            restoredPanelTitleBoundariesByPanelId[panelId] = boundary
        }
    }

    /// Returns whether a raw PTY title has crossed the restored-title boundary.
    func shouldApplyRestoredPanelTitle(panelId: UUID, rawTitle: String) -> Bool {
        guard var boundary = restoredPanelTitleBoundariesByPanelId[panelId] else {
            return true
        }
        let shouldApply = boundary.shouldApply(rawTitle: rawTitle)
        restoredPanelTitleBoundariesByPanelId[panelId] = boundary
        return shouldApply
    }

    /// Advances admission from authoritative shell activity and returns a buffered genuine title.
    func restoredPanelTitleAfterShellActivity(
        panelId: UUID,
        state: PanelShellActivityState
    ) -> String? {
        guard var boundary = restoredPanelTitleBoundariesByPanelId[panelId] else {
            return nil
        }
        let pendingTitle = boundary.observe(shellState: state)
        if boundary.isReleased {
            restoredPanelTitleBoundariesByPanelId.removeValue(forKey: panelId)
        } else {
            restoredPanelTitleBoundariesByPanelId[panelId] = boundary
        }
        return pendingTitle
    }
}
