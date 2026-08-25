extension ShortcutAction {
    /// Whether the app's key router consumes this action before general
    /// configured-shortcut matching whenever its context holds.
    ///
    /// Right-sidebar mode shortcuts win while the sidebar is focused, and browser
    /// hard reload wins while a browser is focused. Conflict detection uses this
    /// to accept priority-resolved pairs such as the factory `⌃1…9` surface
    /// selection alongside the sidebar's `⌃1…5` shortcuts and the legacy
    /// application-scoped Rename Workspace `⌘⇧R` binding alongside hard reload.
    public var hasPriorityShortcutRouting: Bool {
        switch self {
        case .switchRightSidebarToFiles, .switchRightSidebarToFind,
             .switchRightSidebarToSessions, .switchRightSidebarToFeed, .switchRightSidebarToDock,
             .switchRightSidebarToMachines,
             .commandPaletteNext, .commandPalettePrevious,
             .browserHardReload,
             .simulatorHome, .simulatorRotateLeft, .simulatorRotateRight,
             .simulatorToggleAppearance, .simulatorToggleSoftwareKeyboard:
            return true
        default:
            return false
        }
    }
}
