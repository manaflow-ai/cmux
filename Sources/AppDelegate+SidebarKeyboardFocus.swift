import AppKit

/// Focus Sidebar (cx-zjtn.5): the workspace list takes the keyboard, as in
/// cmux-next. Down/Up select the next/previous workspace while the list keeps
/// focus; Return or Escape hand the keyboard back to the selected workspace.
extension AppDelegate {
    /// Reveals the window's workspace sidebar when hidden and focuses its list.
    @discardableResult
    func focusSidebarForKeyboard(preferredWindow: NSWindow?) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow),
              let window = resolvedWindow(for: context) else {
            return false
        }
        if !context.sidebarState.isVisible {
            context.sidebarState.toggle()
        }
        focusSidebarTable(in: window, attemptsLeft: 5)
        return true
    }

    /// Handles a key typed while the workspace list has focus.
    ///
    /// - Returns: `false` for keys the list leaves to AppKit.
    func handleSidebarKeyboardKey(_ event: NSEvent, in table: NSTableView) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
              let window = table.window,
              let manager = contextForMainTerminalWindow(window)?.tabManager else {
            return false
        }
        switch event.keyCode {
        case 125: // Down
            manager.selectNextTab()
        case 126: // Up
            manager.selectPreviousTab()
        case 36, 76, 53: // Return, keypad Enter, Escape
            focusSelectedWorkspacePanel(manager: manager, window: window)
            return true
        default:
            return false
        }
        // Selecting a workspace restores its panel's focus; keep the list
        // focused so the next arrow keeps stepping.
        keepKeyboard(on: table, in: window)
        return true
    }

    private func focusSidebarTable(in window: NSWindow, attemptsLeft: Int) {
        if let table = Self.sidebarTable(in: window.contentView), !table.isHiddenOrHasHiddenAncestor {
            window.makeFirstResponder(table)
            return
        }
        // A sidebar revealed by this call mounts on a later pass.
        guard attemptsLeft > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
            guard let window else { return }
            self?.focusSidebarTable(in: window, attemptsLeft: attemptsLeft - 1)
        }
    }

    private func keepKeyboard(on table: NSTableView, in window: NSWindow) {
        window.makeFirstResponder(table)
        for delay in [0.0, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak table, weak window] in
                guard let table, let window, window.firstResponder !== table else { return }
                window.makeFirstResponder(table)
            }
        }
    }

    private func focusSelectedWorkspacePanel(manager: TabManager, window: NSWindow) {
        _ = window.makeFirstResponder(nil)
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return
        }
        noteMainPanelKeyboardFocusIntent(workspaceId: workspace.id, panelId: panelId, in: window)
        workspace.focusPanel(panelId, focusIntent: panel.preferredFocusIntentForActivation())
    }

    private static func sidebarTable(in view: NSView?) -> SidebarWorkspaceTableViewImpl? {
        guard let view else { return nil }
        if let table = view as? SidebarWorkspaceTableViewImpl { return table }
        for subview in view.subviews {
            if let table = sidebarTable(in: subview) { return table }
        }
        return nil
    }
}
