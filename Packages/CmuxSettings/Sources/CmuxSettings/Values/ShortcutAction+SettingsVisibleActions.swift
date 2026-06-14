/// Keyboard-shortcut action ordering used by Settings UI surfaces.
public extension ShortcutAction {
    /// Actions shown in the Keyboard Shortcuts settings section, in display order.
    static var settingsVisibleActions: [ShortcutAction] {
        orderedSettingsVisibleActions(
            from: allCases.filter { $0 != .showHideAllWindows }
        )
    }
}

private extension ShortcutAction {
    static func orderedSettingsVisibleActions(from actions: [ShortcutAction]) -> [ShortcutAction] {
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
