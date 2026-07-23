import AppKit
import Bonsplit

extension AppDelegate {
    /// Routes adjacent surface navigation and surface/workspace reordering through
    /// the main-window context selected for the key event.
    func handleAdjacentNavigationShortcut(event: NSEvent) -> Bool {
        let routedTabManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager
            ?? tabManager
        if matchConfiguredShortcut(event: event, action: .nextSurface) {
            if performFocusedDockShortcut(.selectNextSurface, event: event) { return true }
            routedTabManager?.selectNextSurface()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .prevSurface) {
            if performFocusedDockShortcut(.selectPreviousSurface, event: event) { return true }
            routedTabManager?.selectPreviousSurface()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveSurfaceLeft) {
            if performFocusedDockShortcut(.moveSurface(offset: -1), event: event) { return true }
            routedTabManager?.selectedWorkspace?.moveSelectedSurface(by: -1)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveSurfaceRight) {
            if performFocusedDockShortcut(.moveSurface(offset: 1), event: event) { return true }
            routedTabManager?.selectedWorkspace?.moveSelectedSurface(by: 1)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveSurfaceToPreviousPane) {
            if routedTabManager?.moveSelectedSurfaceToPane(offset: -1) != true {
                NSSound.beep()
            }
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveSurfaceToNextPane) {
            if routedTabManager?.moveSelectedSurfaceToPane(offset: 1) != true {
                NSSound.beep()
            }
            return true
        }
        let directionalPaneMoveActions: [(KeyboardShortcutSettings.Action, NavigationDirection)] = [
            (.moveSurfaceToPaneLeft, .left),
            (.moveSurfaceToPaneRight, .right),
            (.moveSurfaceToPaneUp, .up),
            (.moveSurfaceToPaneDown, .down),
        ]
        for (action, direction) in directionalPaneMoveActions {
            if matchConfiguredShortcut(event: event, action: action) {
                if routedTabManager?.moveSelectedSurfaceToAdjacentPane(direction) != true {
                    NSSound.beep()
                }
                return true
            }
        }
        if matchConfiguredShortcut(event: event, action: .moveWorkspaceUp) {
            routedTabManager?.moveSelectedWorkspace(by: -1)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveWorkspaceDown) {
            routedTabManager?.moveSelectedWorkspace(by: 1)
            return true
        }
        return false
    }
}
