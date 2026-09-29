import AppKit
import CmuxNextActions

/// Action IDs owned by the app shell.
extension ActionID {
    static let quit: ActionID = "app.quit"
    static let newTab: ActionID = "tab.new"
    static let closeTab: ActionID = "tab.close"
    static let nextTab: ActionID = "tab.next"
    static let previousTab: ActionID = "tab.previous"
    static let toggleSidebar: ActionID = "view.toggleSidebar"
    static let commandPalette: ActionID = "palette.show"
}

/// Registers every shell action once. Menus, the window key router, and
/// (later) the palette and debug socket all resolve through the registry.
enum AppActions {
    static func register(in registry: ActionRegistry, model: ShellModel) {
        registry.register(Action(
            id: .quit,
            title: Strings.actionQuit,
            keywords: ["exit"],
            shortcut: Shortcut("q")
        ) {
            NSApp.terminate(nil)
        })
        registry.register(Action(
            id: .newTab,
            title: Strings.actionNewTab,
            keywords: ["terminal", "open"],
            shortcut: Shortcut("t")
        ) {
            model.addTab()
        })
        registry.register(Action(
            id: .closeTab,
            title: Strings.actionCloseTab,
            shortcut: Shortcut("w"),
            isEnabled: { model.canCloseTab }
        ) {
            model.closeSelectedTab()
        })
        registry.register(Action(
            id: .nextTab,
            title: Strings.actionNextTab,
            shortcut: Shortcut("]", modifiers: [.command, .shift])
        ) {
            model.selectAdjacentTab(offset: 1)
        })
        registry.register(Action(
            id: .previousTab,
            title: Strings.actionPreviousTab,
            shortcut: Shortcut("[", modifiers: [.command, .shift])
        ) {
            model.selectAdjacentTab(offset: -1)
        })
        registry.register(Action(
            id: .toggleSidebar,
            title: Strings.actionToggleSidebar,
            keywords: ["workspaces", "panel"],
            shortcut: Shortcut("b")
        ) {
            model.isSidebarVisible.toggle()
        })
        // Placeholder until the palette agent lands CmuxNextPalette; the
        // shortcut is reserved so nothing else claims Cmd-Shift-P.
        registry.register(Action(
            id: .commandPalette,
            title: Strings.actionCommandPalette,
            keywords: ["actions", "search"],
            shortcut: Shortcut("p", modifiers: [.command, .shift])
        ) {
            NSSound.beep()
        })
    }
}
