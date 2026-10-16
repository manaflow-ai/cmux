extension KeyboardShortcutSettings.Action {
    /// Whether this action is part of the public, user-configurable shortcut catalog.
    var isPublicShortcutAction: Bool {
        switch self {
        case .switchRightSidebarToFiles,
             .switchRightSidebarToFind,
             .switchRightSidebarToSessions,
             .switchRightSidebarToFeed,
             .switchRightSidebarToDock,
             .switchRightSidebarToMachines,
             .switchRightSidebarToSnippets:
            return false
        default:
            return true
        }
    }
}
