import AppKit

/// `left_sidebar` (`cmux left-sidebar`): show, hide, focus and read the
/// workspace sidebar from the CLI.
extension AppDelegate {
    /// Applies a left-sidebar command to the targeted window, or to the window
    /// ⌘B would act on when no target is given.
    ///
    /// Visibility changes go straight to the window's `SidebarState`, so a
    /// background caller never makes a window key or activates the app; this
    /// is stricter than `right_sidebar`, whose `toggle` and `show` may. Only
    /// `focus` brings the window forward, through the Focus Sidebar path.
    func applyLeftSidebarRemoteCommand(
        _ command: LeftSidebarRemoteCommand,
        target: SidebarRemoteTarget = SidebarRemoteTarget()
    ) -> LeftSidebarRemoteApplyResult {
        let context: MainWindowContext
        let window: NSWindow?
        if target.isActiveTarget {
            guard let active = sidebarToggleTarget() else {
                return .failure(String(localized: "leftSidebar.remote.error.unavailable", defaultValue: "ERROR: Left sidebar not available"))
            }
            context = active.context
            window = active.window
        } else {
            guard let targeted = sidebarRemoteContext(target: target) else {
                return .failure(String(localized: "leftSidebar.remote.error.targetNotFound", defaultValue: "ERROR: Left sidebar target not found"))
            }
            context = targeted
            window = resolvedWindow(for: targeted)
        }

        let state = context.sidebarState
        switch command {
        case .toggle:
            state.toggle()
        case .show:
            state.setVisible(true)
        case .hide:
            // A sidebar collapsed for lack of room would otherwise come back
            // when the window widens; a hidden one stays hidden.
            state.isAutoCollapsed = false
            state.setVisible(false)
        case .focus:
            guard let window else {
                return .failure(String(localized: "leftSidebar.remote.error.focusFailed", defaultValue: "ERROR: Failed to focus left sidebar"))
            }
            mainWindowVisibilityController.focusForInWindowCommand(window, reason: .leftSidebarFocus)
            guard focusSidebarForKeyboard(preferredWindow: window) else {
                return .failure(String(localized: "leftSidebar.remote.error.focusFailed", defaultValue: "ERROR: Failed to focus left sidebar"))
            }
        case .getState:
            return .state(visible: state.isVisible)
        }
        return .ok
    }
}
