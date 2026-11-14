import AppKit

extension SidebarWorkspaceRowMenuBuilder {
    /// The session-priority items, shown only while the setting is on. Same
    /// titles and actions as the SwiftUI menu (`TabItemView+SessionPriority`).
    func addSessionPrioritySection(to menu: NSMenu, tabManager: TabManager) {
        guard SessionPriorityCoordinator.shared.isEnabled else { return }
        let state = SessionPriorityMenuState(workspace: commands.tab)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for difficulty in SessionPriorityActions.difficultyChoices {
            let entry = menuItem(SessionPriorityActions.difficultyTitle(difficulty)) { [weak tabManager, commands] in
                guard let tabManager else { return }
                SessionPriorityActions.applyDifficulty(
                    difficulty,
                    to: SidebarWorkspaceRowMenuBuilder(commands: commands).targetWorkspaces(tabManager)
                )
            }
            entry.state = difficulty == state.difficultyOverride ? .on : .off
            submenu.addItem(entry)
        }
        let parent = menuItem(SessionPriorityActions.difficultyMenuTitle) {}
        parent.submenu = submenu
        menu.addItem(parent)

        let adjustableManual = state.adjustableManual
        menu.addItem(menuItem(SessionPriorityActions.manualItemTitle(adjustableManual: adjustableManual)) {
            [weak tabManager, commands] in
            guard let tabManager else { return }
            SessionPriorityActions.setManual(
                !adjustableManual,
                for: SidebarWorkspaceRowMenuBuilder(commands: commands).targetWorkspaces(tabManager)
            )
        })
        menu.addItem(.separator())
    }
}
