public import CmuxNextActions
public import CmuxNextSettings
public import CmuxNextSidebar

/// Every action this package binds, from one call at the composition root (AppActions): archive,
/// auto-archive, the compact workspace list toggle, and Reveal Workspace in Sidebar.
@MainActor
public struct SidebarActionSet {
    private let host: any SidebarArchiveHost
    private let autoArchive: AutoArchiveCoordinator
    private let settings: @MainActor () -> SettingsController?
    private let sidebar: @MainActor () -> SidebarView?

    /// - Parameters:
    ///   - host: What the archive actions read from the App; its workspace lookup also names a reveal's target.
    ///   - autoArchive: The auto-archive sweep and rules.
    ///   - settings: The settings controller the compact list toggle writes through.
    ///   - sidebar: The active window's sidebar, which Reveal Workspace in Sidebar shows; nil with no window.
    public init(host: any SidebarArchiveHost, autoArchive: AutoArchiveCoordinator, settings: @escaping @MainActor () -> SettingsController?,
                sidebar: @escaping @MainActor () -> SidebarView?) {
        self.host = host
        self.autoArchive = autoArchive
        self.settings = settings
        self.sidebar = sidebar
    }

    public func bind(into registry: ActionRegistry) {
        SidebarArchiveActions(host: host).bind(into: registry)
        AutoArchiveActions(coordinator: autoArchive, host: host).bind(into: registry)
        SidebarCompactListToggle(settings: settings).bind(into: registry)
        let host = host
        SidebarRevealActions(workspace: { try? host.archiveWorkspace($0) }, sidebar: sidebar).bind(into: registry)
    }
}
