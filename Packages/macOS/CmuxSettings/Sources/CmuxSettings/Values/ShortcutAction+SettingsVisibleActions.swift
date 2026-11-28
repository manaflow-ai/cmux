import os

/// Keyboard-shortcut action ordering used by Settings UI surfaces.
public extension ShortcutAction {
    /// Actions shown in the Keyboard Shortcuts settings section, in display order.
    /// Leaves out actions the host doesn't offer now (``hostUnavailableActions``).
    static var settingsVisibleActions: [ShortcutAction] {
        settingsVisibleActions(hiding: hostUnavailableActions)
    }

    /// ``settingsVisibleActions`` with `hidden` left out as well.
    static func settingsVisibleActions(hiding hidden: Set<ShortcutAction>) -> [ShortcutAction] {
        orderedSettingsVisibleActions(
            from: allCases.filter { $0 != .showHideAllWindows && !hidden.contains($0) }
        )
    }

    /// Actions whose feature the host doesn't offer right now, such as Open
    /// Chief while Chief's release flag is off. Settings lists and conflict
    /// checks skip them. Read on every call, so a flag change applies at once.
    static var hostUnavailableActions: Set<ShortcutAction> {
        hostUnavailableActionsProvider.withLock { $0 }()
    }

    /// Installs the host's ``hostUnavailableActions`` source. The app calls
    /// this once at launch; without it every action is offered.
    static func setHostUnavailableActionsProvider(
        _ provider: @escaping @Sendable () -> Set<ShortcutAction>
    ) {
        hostUnavailableActionsProvider.withLock { $0 = provider }
    }
}

private let hostUnavailableActionsProvider = OSAllocatedUnfairLock<@Sendable () -> Set<ShortcutAction>>(
    initialState: { [] }
)

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
