import CmuxWorkspaces
import Foundation

/// The window-side host for the CmuxWorkspaces focused-surface model: the
/// focus/unfocus mutations the focus-restore and deferred-unfocus state
/// machine performs, mirroring the legacy `unfocusWorkspacePanel` /
/// `tab.focusPanel` lookups so a gone workspace/panel makes every mutation a
/// no-op.
///
/// `selectedWorkspaceId`, `panelExists(workspaceId:panelId:)`,
/// `workspaceFocusedPanelId(_:)`, and `focusPanel(workspaceId:panelId:)` are
/// already witnessed by the NotificationDismissalHosting / SidebarGitHosting /
/// FocusHistoryHosting conformances; one declaration satisfies all seams.
/// `logPendingWorkspaceUnfocusEvent(_:)` lives in `TabManager.swift` because it
/// reads the `private` DEBUG workspace-switch snapshot and formatter helpers.
extension TabManager: FocusedSurfaceHosting {
    func unfocusPanel(workspaceId: UUID, panelId: UUID) {
        guard let tab = tabs.first(where: { $0.id == workspaceId }),
              let panel = tab.panels[panelId] else { return }
        panel.unfocus()
    }
}
