public import CmuxNextActions
public import CmuxNextSidebar

/// Every action this package binds, from one call at the composition root (AppActions): archive,
/// auto-archive and the compact workspace list toggle.
@MainActor
public struct SidebarActionSet {
    private let host: any SidebarArchiveHost
    private let autoArchive: AutoArchiveCoordinator

    public init(host: any SidebarArchiveHost, autoArchive: AutoArchiveCoordinator) {
        self.host = host
        self.autoArchive = autoArchive
    }

    public func bind(into registry: ActionRegistry) {
        SidebarArchiveActions(host: host).bind(into: registry)
        AutoArchiveActions(coordinator: autoArchive, host: host).bind(into: registry)
        SidebarCompactListToggle().bind(into: registry)
    }
}
