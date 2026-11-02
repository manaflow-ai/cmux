import CmuxCore
import Foundation

extension Workspace {
    /// Sets or clears (`nil`) the badge shown before a panel's title, and
    /// refreshes its tab, the workspace title and the window title.
    ///
    /// Setting the current value again still refreshes the tab, so a label
    /// some other path overwrote is repaired.
    ///
    /// - Returns: `false` if the panel does not exist.
    @discardableResult
    func setPanelBadge(panelId: UUID, badge: PanelBadgeText?) -> Bool {
        guard let panel = panels[panelId] else { return false }
        let previousTitle = title
        if panelBadges[panelId] != badge {
            panelBadges[panelId] = badge
        }
        _ = applyFocusedPanelTitle(panelId: panelId)
        refreshTabTitle(panelId: panelId, panel: panel)
        if title != previousTitle {
            owningTabManager?.panelCustomTitleDidReconcileWorkspaceTitle(self)
        }
        return true
    }
}
