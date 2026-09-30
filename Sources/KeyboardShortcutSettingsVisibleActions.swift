import Foundation

extension KeyboardShortcutSettings {
    static var settingsVisibleActions: [Action] {
        orderedSettingsVisibleActions(
            from: publicShortcutActions.filter { $0 != .showHideAllWindows }
        )
    }

    private static func orderedSettingsVisibleActions(from actions: [Action]) -> [Action] {
        let colocatedSidebarActions = [
            .focusRightSidebar,
            .toggleRightSidebar,
            .findInDirectory,
            .fileExplorerOpenSelection,
            .fileExplorerOpenSelectionFinderAlias,
        ].filter(actions.contains)
        let actionSet = Set(colocatedSidebarActions)
        let baseActions = actions.filter { !actionSet.contains($0) }

        guard let anchorIndex = baseActions.firstIndex(of: .markOldestUnreadAndJumpNext)
            ?? baseActions.firstIndex(of: .jumpToUnread) else {
            return colocatedSidebarActions + baseActions
        }

        var orderedActions = baseActions
        orderedActions.insert(contentsOf: colocatedSidebarActions, at: anchorIndex + 1)
        return orderedActions
    }
}
