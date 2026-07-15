import AppKit
import Bonsplit
import CmuxPanes

/// Routes "create a surface" keyboard shortcuts (New Browser, New Terminal,
/// Split Right/Down) into the Dock when the Dock currently owns keyboard focus.
///
/// Without this, every creation shortcut targets the main content `tabManager`,
/// so pressing e.g. Cmd+Shift+L while a Dock pane is focused spawned a browser in
/// the main split tree instead of the Dock. Mirrors the existing focus-gated
/// routing in `closeFocusedDockPanelForCommand` (`Workspace+DockBrowserLookup.swift`):
/// the gate is `activeRightSidebarMode == .dock`, and the right-sidebar Dock is
/// that window's own Dock (`RightSidebarPanelView` renders the per-window store).
extension AppDelegate {
    /// The Dock store that should receive a creation/split shortcut when the Dock
    /// owns keyboard focus in `preferredWindow`, else `nil` (caller falls through
    /// to the main-area path).
    func focusedDockStoreForShortcut(preferredWindow: NSWindow?) -> DockSplitStore? {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            return nil
        }
        guard context.keyboardFocusCoordinator.activeRightSidebarMode == .dock else {
            return nil
        }
        // Dock mode showing means the right sidebar rendered this window's own
        // Dock (which created it), so this resolves the store already on screen.
        // No workspace-Dock fallback: the sidebar never renders one, so routing
        // a creation shortcut there would target an invisible tree.
        return windowDock(forWindowId: context.windowId)
    }

    /// Creates a New Terminal / New Browser surface in the focused Dock pane.
    /// Returns the created Dock panel id when handled, or `nil` to fall through to
    /// the main-area creation path.
    @discardableResult
    func routeCreateToFocusedDock(
        _ kind: DockSurfaceKind,
        focusAddressBar: Bool,
        preferredWindow: NSWindow?
    ) -> UUID? {
        if kind == .browser, !BrowserAvailabilitySettings.isEnabled() {
            return nil
        }
        guard let store = focusedDockStoreForShortcut(preferredWindow: preferredWindow),
              let pane = store.resolvePane(requestedPaneID: nil),
              let panelId = store.newSurface(kind: kind, inPane: pane, focus: true) else {
            return nil
        }
        if focusAddressBar, kind == .browser, let browser = store.browserPanel(for: panelId) {
            focusBrowserAddressBar(in: browser)
        }
        return panelId
    }

    /// Splits the focused Dock pane (terminal or browser). Returns `true` when
    /// handled, or `false` to fall through to the main-area split path. Reuses the
    /// main area's `SplitDirection` → orientation/insert mapping so Dock splits
    /// match the main split affordances (Cmd+D = side-by-side, Cmd+Shift+D = stacked).
    @discardableResult
    func routeSplitToFocusedDock(
        kind: DockSurfaceKind,
        direction: SplitDirection,
        preferredWindow: NSWindow?
    ) -> Bool {
        if kind == .browser, !BrowserAvailabilitySettings.isEnabled() {
            return false
        }
        guard let store = focusedDockStoreForShortcut(preferredWindow: preferredWindow) else {
            return false
        }
        return store.newSplit(
            kind: kind,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            sourcePanelId: store.focusedPanelId,
            focus: true
        ) != nil
    }

    /// Routes configurable surface/focus commands through the focused Dock's
    /// own controller. Configurable matching stays in `KeyboardShortcutSettings`,
    /// while the existing legacy-tab and Ghostty compatibility resolvers are
    /// shared with the main-area dispatcher. The Dock receives only semantic
    /// commands and never duplicates those bindings.
    func handleFocusedDockSurfaceShortcut(event: NSEvent) -> Bool {
        guard let store = focusedDockStoreForShortcut(preferredWindow: event.window) else {
            return false
        }

        let commands: [(KeyboardShortcutSettings.Action, DockShortcutCommand)] = [
            (.nextSurface, .selectNextSurface),
            (.prevSurface, .selectPreviousSurface),
            (.moveSurfaceLeft, .moveSurface(offset: -1)),
            (.moveSurfaceRight, .moveSurface(offset: 1)),
            (.toggleSplitZoom, .togglePaneZoom),
            (.triggerFlash, .triggerFlash),
        ]
        for (action, command) in commands where matchConfiguredShortcut(event: event, action: action) {
            if !store.performShortcutCommand(command) { NSSound.beep() }
            return true
        }

        if matchesLegacyNextSurfaceShortcut(event: event) {
            if !store.performShortcutCommand(.selectNextSurface) { NSSound.beep() }
            return true
        }
        if matchesLegacyPreviousSurfaceShortcut(event: event) {
            if !store.performShortcutCommand(.selectPreviousSurface) { NSSound.beep() }
            return true
        }

        if let digit = routableNumberedConfiguredShortcutDigit(event: event, action: .selectSurfaceByNumber) {
            if !store.performShortcutCommand(.selectSurface(number: digit)) { NSSound.beep() }
            return true
        }

        let directionalCommands: [(
            action: KeyboardShortcutSettings.Action,
            glyph: String,
            keyCode: UInt16,
            direction: NavigationDirection,
            command: DockShortcutCommand
        )] = [
            (.focusLeft, "←", 123, .left, .focusPane(.left)),
            (.focusRight, "→", 124, .right, .focusPane(.right)),
            (.focusUp, "↑", 126, .up, .focusPane(.up)),
            (.focusDown, "↓", 125, .down, .focusPane(.down)),
        ]
        for route in directionalCommands where (
            matchConfiguredDirectionalShortcut(
                event: event,
                action: route.action,
                arrowGlyph: route.glyph,
                arrowKeyCode: route.keyCode
            ) || matchesGhosttyGotoSplitShortcut(event: event, direction: route.direction)
        ) {
            if !store.performShortcutCommand(route.command) { NSSound.beep() }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .focusHistoryBack) {
            if !store.performShortcutCommand(.focusHistoryBack) { NSSound.beep() }
            return true
        }
        if matchConfiguredShortcut(event: event, action: .focusHistoryForward) {
            if !store.performShortcutCommand(.focusHistoryForward) { NSSound.beep() }
            return true
        }
        return false
    }

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

    func matchesGhosttyGotoSplitShortcut(event: NSEvent, direction: NavigationDirection) -> Bool {
        guard let shortcut = ghosttyGotoSplitShortcut(for: direction) else { return false }
        let route: (glyph: String, keyCode: UInt16) = switch direction {
        case .left: ("←", 123)
        case .right: ("→", 124)
        case .up: ("↑", 126)
        case .down: ("↓", 125)
        }
        return matchDirectionalShortcut(
            event: event,
            shortcut: shortcut,
            arrowGlyph: route.glyph,
            arrowKeyCode: route.keyCode
        )
    }
}
