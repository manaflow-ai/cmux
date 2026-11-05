public import CmuxNextActions
public import CmuxNextDesignTokens
public import CmuxNextSettings
public import CmuxNextSidebar

/// Every action this package binds, from one call at the composition root (AppActions): archive,
/// auto-archive, a group's Sort, the compact workspace list toggle, Reveal Workspace in Sidebar and the Sidebar States Playground.
@MainActor
public struct SidebarActionSet {
    private let host: any SidebarArchiveHost
    private let autoArchive: AutoArchiveCoordinator
    private let settings: @MainActor () -> SettingsController?
    private let sidebar: @MainActor () -> SidebarView?
    private let themeColors: @MainActor () -> [String: ThemeFileColors]
    private let playgroundSections: @MainActor () -> [SidebarStatesPlaygroundSection]

    /// - Parameters:
    ///   - host: What the archive actions read from the App; its workspace lookup also names a reveal's target.
    ///   - autoArchive: The auto-archive sweep and rules.
    ///   - settings: The settings controller the compact list toggle writes through.
    ///   - sidebar: The active window's sidebar, which Reveal Workspace in Sidebar shows; nil with no window.
    ///   - themeColors: Every theme file's colors by name, for the Sidebar States Playground's sheets
    ///     (``SidebarStatesPlaygroundAction``); none leaves them in the window's theme.
    ///   - playgroundSections: Sections other packages draw in the Sidebar States Playground (the App's Home filter).
    public init(host: any SidebarArchiveHost, autoArchive: AutoArchiveCoordinator, settings: @escaping @MainActor () -> SettingsController?,
                sidebar: @escaping @MainActor () -> SidebarView?, themeColors: @escaping @MainActor () -> [String: ThemeFileColors] = { [:] },
                playgroundSections: @escaping @MainActor () -> [SidebarStatesPlaygroundSection] = { [] }) {
        self.host = host
        self.autoArchive = autoArchive
        self.settings = settings
        self.sidebar = sidebar
        self.themeColors = themeColors
        self.playgroundSections = playgroundSections
    }

    public func bind(into registry: ActionRegistry) {
        SidebarArchiveActions(host: host).bind(into: registry)
        AutoArchiveActions(coordinator: autoArchive, host: host).bind(into: registry)
        SidebarGroupSortActions(host: host).bind(into: registry)
        SidebarCompactListToggle(settings: settings).bind(into: registry)
        let host = host
        SidebarRevealActions(workspace: { try? host.archiveWorkspace($0) }, sidebar: sidebar).bind(into: registry)
        SidebarStatesPlaygroundAction(themeColors: themeColors, sections: playgroundSections).bind(into: registry)
    }
}
