import CmuxControlSocket
import Foundation

/// `sidebar.group_by` witness. Reads or sets the resolved window's Group By
/// mode directly on its `TabManager`: a data change that never activates the
/// app, raises the window or switches the sidebar view (the Views menu and
/// command palette do that through `TabManager.selectSidebarGroupBy`).
extension TerminalController {
    func controlSidebarGroupBy(
        routing: ControlRoutingSelectors,
        mode: String?
    ) -> ControlSidebarGroupByResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let windowId = AppDelegate.shared?.windowId(for: tabManager) else {
            return .windowNotFound
        }
        if let mode {
            guard let parsed = SidebarGroupByMode(rawValue: mode) else { return .invalidMode }
            tabManager.sidebarGroupBy.mode = parsed
        }
        return .resolved(windowID: windowId, mode: tabManager.sidebarGroupBy.mode.rawValue)
    }
}
