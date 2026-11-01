public import CmuxNextActions
public import CmuxNextSettings
public import CmuxNextSidebar

/// Every action this package binds, from one call at the composition root (AppActions): archive,
/// auto-archive and the compact workspace list toggle.
@MainActor
public struct SidebarActionSet {
    private let host: any SidebarArchiveHost
    private let autoArchive: AutoArchiveCoordinator
    private let settings: @MainActor () -> SettingsController?

    public init(host: any SidebarArchiveHost, autoArchive: AutoArchiveCoordinator, settings: @escaping @MainActor () -> SettingsController?) {
        self.host = host
        self.autoArchive = autoArchive
        self.settings = settings
    }

    public func bind(into registry: ActionRegistry) {
        SidebarArchiveActions(host: host).bind(into: registry)
        AutoArchiveActions(coordinator: autoArchive, host: host).bind(into: registry)
        SidebarCompactListToggle(settings: settings).bind(into: registry)
    }
}
