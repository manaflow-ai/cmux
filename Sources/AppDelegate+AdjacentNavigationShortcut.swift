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
        if matchConfiguredDirectionalShortcut(
            event: event,
            action: .moveSurfaceToPreviousPane,
            arrowGlyph: "←",
            arrowKeyCode: 123
        ) {
            performSurfacePaneMoveShortcut(event: event) {
                routedTabManager?.moveSelectedSurfaceToPane(offset: -1) == true
            }
            return true
        }
        if matchConfiguredDirectionalShortcut(
            event: event,
            action: .moveSurfaceToNextPane,
            arrowGlyph: "→",
            arrowKeyCode: 124
        ) {
            performSurfacePaneMoveShortcut(event: event) {
                routedTabManager?.moveSelectedSurfaceToPane(offset: 1) == true
            }
            return true
        }
        let directionalPaneMoveActions: [(KeyboardShortcutSettings.Action, NavigationDirection, String, UInt16)] = [
            (.moveSurfaceToPaneLeft, .left, "←", 123),
            (.moveSurfaceToPaneRight, .right, "→", 124),
            (.moveSurfaceToPaneUp, .up, "↑", 126),
            (.moveSurfaceToPaneDown, .down, "↓", 125),
        ]
        for (action, direction, arrowGlyph, arrowKeyCode) in directionalPaneMoveActions {
            if matchConfiguredDirectionalShortcut(
                event: event,
                action: action,
                arrowGlyph: arrowGlyph,
                arrowKeyCode: arrowKeyCode
            ) {
                performSurfacePaneMoveShortcut(event: event) {
                    routedTabManager?.moveSelectedSurfaceToAdjacentPane(direction) == true
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

    private func performSurfacePaneMoveShortcut(event: NSEvent, operation: () -> Bool) {
        guard focusedDockStoreForShortcut(preferredWindow: event.window) == nil,
              operation() else {
            NSSound.beep()
            return
        }
    }
}
