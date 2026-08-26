extension ShortcutAction {
    /// Whether the app's key router consumes this action before general
    /// configured-shortcut matching whenever its context holds.
    ///
    /// Right-sidebar mode shortcuts win while the sidebar is focused. Conflict
    /// detection uses this to accept priority-resolved pairs such as the factory
    /// `⌃1…9` surface selection alongside the sidebar's `⌃1…5` shortcuts.
    public var hasPriorityShortcutRouting: Bool {
        switch self {
        case .switchRightSidebarToFiles, .switchRightSidebarToFind,
             .switchRightSidebarToSessions, .switchRightSidebarToFeed, .switchRightSidebarToDock,
             .switchRightSidebarToMachines,
             .commandPaletteNext, .commandPalettePrevious,
             .simulatorHome, .simulatorRotateLeft, .simulatorRotateRight,
             .simulatorToggleAppearance, .simulatorToggleSoftwareKeyboard:
            return true
        default:
            return false
        }
    }

    /// Whether this action wins conflict arbitration against another action.
    ///
    /// Most priority routing is described by ``hasPriorityShortcutRouting``.
    /// The legacy ``browserHardReload``/``renameWorkspace`` overlap is an
    /// explicit compatibility exception: runtime dispatch checks hard reload
    /// before the old application-scoped rename binding when a browser is
    /// focused, while rename remains available in other contexts. Keeping the
    /// exception here makes the app runtime and Settings recorder share one
    /// conflict policy.
    ///
    /// - Parameter other: The action whose binding is being compared.
    /// - Returns: `true` when this action is the priority side for the pair.
    public func hasPriorityForShortcutConflict(with other: ShortcutAction) -> Bool {
        hasPriorityShortcutRouting
            || (self == .browserHardReload && other == .renameWorkspace)
    }
}
