import AppKit

extension AppDelegate {
    /// Routes adjacent surface navigation and surface/workspace reordering through
    /// the main-window context selected for the key event.
    func handleAdjacentNavigationShortcut(event: NSEvent) -> Bool {
        if matchConfiguredShortcut(event: event, action: .nextSurface) {
            if performFocusedDockShortcut(.selectNextSurface, event: event) { return true }
            (preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager)?.selectNextSurface()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .prevSurface) {
            if performFocusedDockShortcut(.selectPreviousSurface, event: event) { return true }
            (preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager)?.selectPreviousSurface()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveSurfaceLeft) {
            if performFocusedDockShortcut(.moveSurface(offset: -1), event: event) { return true }
            (preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager)?.selectedWorkspace?.moveSelectedSurface(by: -1)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveSurfaceRight) {
            if performFocusedDockShortcut(.moveSurface(offset: 1), event: event) { return true }
            (preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager)?.selectedWorkspace?.moveSelectedSurface(by: 1)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveWorkspaceUp) {
            (preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager)?.moveSelectedWorkspace(by: -1)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveWorkspaceDown) {
            (preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager)?.moveSelectedWorkspace(by: 1)
            return true
        }
        return false
    }
}
