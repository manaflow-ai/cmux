import AppKit
import Bonsplit

extension AppDelegate {
    func matchesLegacyNextSurfaceShortcut(event: NSEvent) -> Bool {
        matchTabShortcut(
            event: event,
            shortcut: StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true)
        )
    }

    func matchesLegacyPreviousSurfaceShortcut(event: NSEvent) -> Bool {
        matchTabShortcut(
            event: event,
            shortcut: StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true)
        )
    }

    func ghosttyGotoSplitShortcut(for direction: NavigationDirection) -> StoredShortcut? {
        switch direction {
        case .left: ghosttyGotoSplitLeftShortcut
        case .right: ghosttyGotoSplitRightShortcut
        case .up: ghosttyGotoSplitUpShortcut
        case .down: ghosttyGotoSplitDownShortcut
        }
    }

    func ghosttyGotoSplitShortcut(for route: GhosttyGotoSplitRoute) -> StoredShortcut? {
        switch route {
        case let .direction(direction):
            ghosttyGotoSplitShortcut(for: direction)
        case .previous:
            ghosttyGotoSplitPreviousShortcut
        case .next:
            ghosttyGotoSplitNextShortcut
        }
    }

    /// Ghostty's imported `goto_split` bindings are compatibility fallbacks, not
    /// peers of cmux's live shortcut configuration. Any configured cmux action
    /// that currently owns the stroke wins. Keeping this arbitration in one
    /// place prevents cached Ghostty bindings from shadowing later handlers
    /// after a Settings rebind.
    func matchesGhosttyGotoSplitFallback(
        event: NSEvent,
        route: GhosttyGotoSplitRoute
    ) -> Bool {
        guard event.type == .keyDown,
              let shortcut = ghosttyGotoSplitShortcut(for: route),
              matchesRawGhosttyGotoSplitShortcut(
                  event: event,
                  shortcut: shortcut,
                  route: route
              ) else {
            return false
        }

        return !KeyboardShortcutSettings.Action.allCases.contains { action in
            guard action.participatesInGhosttyGotoSplitArbitration else {
                return false
            }
            return liveConfiguredShortcut(action, owns: event)
        }
    }

    private func matchesRawGhosttyGotoSplitShortcut(
        event: NSEvent,
        shortcut: StoredShortcut,
        route: GhosttyGotoSplitRoute
    ) -> Bool {
        switch route {
        case let .direction(direction):
            let directionalKey = directionalArrowKey(for: direction)
            return matchDirectionalShortcut(
                event: event,
                shortcut: shortcut,
                arrowGlyph: directionalKey.glyph,
                arrowKeyCode: directionalKey.keyCode
            )
        case .previous, .next:
            guard !shortcut.hasChord else { return false }
            return matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
        }
    }

    private func liveConfiguredShortcut(
        _ action: KeyboardShortcutSettings.Action,
        owns event: NSEvent
    ) -> Bool {
        if action.usesNumberedDigitMatching {
            return routableNumberedConfiguredShortcutDigit(
                event: event,
                action: action
            ) != nil
        }

        let directionalKey: (glyph: String, keyCode: UInt16)? = switch action {
        case .focusLeft: directionalArrowKey(for: .left)
        case .focusRight: directionalArrowKey(for: .right)
        case .focusUp: directionalArrowKey(for: .up)
        case .focusDown: directionalArrowKey(for: .down)
        default: nil
        }
        if let directionalKey {
            return matchConfiguredDirectionalShortcut(
                event: event,
                action: action,
                arrowGlyph: directionalKey.glyph,
                arrowKeyCode: directionalKey.keyCode
            )
        }
        return matchConfiguredShortcut(event: event, action: action)
    }

    private func directionalArrowKey(
        for direction: NavigationDirection
    ) -> (glyph: String, keyCode: UInt16) {
        switch direction {
        case .left: ("←", 123)
        case .right: ("→", 124)
        case .up: ("↑", 126)
        case .down: ("↓", 125)
        }
    }

    /// Routes adjacent surface navigation and surface/workspace reordering through
    /// the main-window context selected for the key event.
    func handleAdjacentNavigationShortcut(event: NSEvent) -> Bool {
        let routedTabs = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager
            ?? tabManager
        if matchConfiguredShortcut(event: event, action: .nextSurface) {
            if performFocusedDockShortcut(
                .selectNextSurface,
                action: .nextSurface,
                event: event
            ) {
                return true
            }
            routedTabs?.selectNextSurface()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .prevSurface) {
            if performFocusedDockShortcut(
                .selectPreviousSurface,
                action: .prevSurface,
                event: event
            ) {
                return true
            }
            routedTabs?.selectPreviousSurface()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveSurfaceLeft) {
            if performFocusedDockShortcut(
                .moveSurface(offset: -1),
                action: .moveSurfaceLeft,
                event: event
            ) {
                return true
            }
            routedTabs?.selectedWorkspace?.moveSelectedSurface(by: -1)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveSurfaceRight) {
            if performFocusedDockShortcut(
                .moveSurface(offset: 1),
                action: .moveSurfaceRight,
                event: event
            ) {
                return true
            }
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
        if let dock = focusedDockStoreForShortcut(
            action: movement.shortcutAction,
            preferredWindow: preferredWindow
        ) {
            return dock.performShortcutCommand(
                .moveSurfaceToPane(
                    movement,
                    allowMissingDestinationSplit:
                        allowMissingDestinationSplit
                )
            )
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
