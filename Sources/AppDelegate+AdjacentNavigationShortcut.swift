import AppKit

extension AppDelegate {
    /// Routes adjacent surface navigation and surface/workspace reordering through
    /// the main-window context selected for the key event.
    func handleAdjacentNavigationShortcut(event: NSEvent) -> Bool {
        let routedTabs = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager
            ?? tabManager
        if matchConfiguredShortcut(event: event, action: .nextSurface) {
            if performFocusedDockShortcut(.selectNextSurface, event: event) { return true }
            routedTabs?.selectNextSurface()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .prevSurface) {
            if performFocusedDockShortcut(.selectPreviousSurface, event: event) { return true }
            routedTabs?.selectPreviousSurface()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveSurfaceLeft) {
            if performFocusedDockShortcut(.moveSurface(offset: -1), event: event) { return true }
            routedTabs?.selectedWorkspace?.moveSelectedSurface(by: -1)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveSurfaceRight) {
            if performFocusedDockShortcut(.moveSurface(offset: 1), event: event) { return true }
            routedTabs?.selectedWorkspace?.moveSelectedSurface(by: 1)
            return true
        }
        for movement in SurfacePaneMovement.allCases
        where matchesSurfacePaneMovementShortcut(event: event, movement: movement) {
            // Repeats may traverse existing panes but must not recursively create splits.
            if !performSurfacePaneMovement(
                movement,
                tabManager: routedTabs,
                preferredWindow: event.window,
                allowMissingDestinationSplit: !event.isARepeat
            ) {
                NSSound.beep()
            }
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveWorkspaceUp) {
            routedTabs?.moveSelectedWorkspace(by: -1)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveWorkspaceDown) {
            routedTabs?.moveSelectedWorkspace(by: 1)
            return true
        }
        return false
    }

    /// Applies the shared Dock-focus gate used by shortcuts, the command
    /// palette, and the View menu.
    @discardableResult
    func performSurfacePaneMovement(
        _ movement: SurfacePaneMovement,
        tabManager: TabManager?,
        preferredWindow: NSWindow?,
        allowMissingDestinationSplit: Bool = true
    ) -> Bool {
        guard focusedDockStoreForShortcut(preferredWindow: preferredWindow) == nil else {
            return false
        }
        return tabManager?.selectedWorkspace?.moveFocusedSurface(
            to: movement,
            allowMissingDestinationSplit: allowMissingDestinationSplit
        ) == true
    }

    private func matchesSurfacePaneMovementShortcut(
        event: NSEvent,
        movement: SurfacePaneMovement
    ) -> Bool {
        let configuredShortcut = KeyboardShortcutSettings.shortcut(
            for: movement.shortcutAction
        )
        let configuredKey =
            configuredShortcut.secondStroke?.key ??
            configuredShortcut.firstStroke.key
        let arrowRoute: (glyph: String, keyCode: UInt16) = switch configuredKey {
        case "→": ("→", 124)
        case "↑": ("↑", 126)
        case "↓": ("↓", 125)
        default: ("←", 123)
        }
        return matchConfiguredDirectionalShortcut(
            event: event,
            action: movement.shortcutAction,
            arrowGlyph: arrowRoute.glyph,
            arrowKeyCode: arrowRoute.keyCode
        )
    }
}
