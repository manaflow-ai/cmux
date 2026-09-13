import AppKit

extension AppDelegate {
    /// Handles the GUI Mode shortcut through the same coordinator used by the tab-bar button.
    func handleGuiModeShortcut(_ event: NSEvent) -> Bool {
        guard matchConfiguredShortcut(event: event, action: .newGuiMode),
              let manager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager else {
            return false
        }
        _ = GuiModeWorkspaceCoordinator().createHomeWorkspace(in: manager)
        return true
    }
}
