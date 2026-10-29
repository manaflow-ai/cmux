import CmuxNextActions
import CmuxNextPalette
import CmuxNextSidebar

/// Go to Workspace's groups, panes and tabs over the App's mirror: the
/// groups of the active window's sidebar, the panes and tabs of every
/// connected machine (the topology Search Tabs reads), recency from the
/// location trail. Choosing a row takes the same path as its other
/// entrypoints: a group as Next Workspace Group, a pane as `pane.focus`, a
/// tab as Search Tabs.
final class AppPaletteNavigationSource: PaletteNavigationSource {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func navigationEntries() -> [PaletteNavigationEntry] {
        guard let services else { return [] }
        let entries = PaletteNavigationEntries.entries(ControlSnapshotPublisher.topology(services), groups: Self.groups(services),
                                                       lastActive: TabSearchFactsBuilder.lastActive(services),
                                                       closing: TabSearchFactsBuilder.closing(services))
        // Agent chats and page tabs read as their tab strip names them, not their `about:blank` record.
        let resolver = TabTitleResolver(services: services)
        let daemons = services.machines.daemons
        return PaletteNavigationEntries.titled(entries) { entry in
            guard let tab = daemons.lazy.compactMap({ $0.store.tab(id: entry.id) }).first else { return nil }
            var titles = resolver
            titles.workspaceName = entry.workspaceTitle
            return titles.title(tab)
        }
    }

    func open(_ entry: PaletteNavigationEntry) {
        guard let services else { return }
        switch entry.kind {
        case .group:
            guard WorkspaceGroupFocus.go(to: CmuxNextSidebar.GroupID(entry.id), services: services) else {
                return services.registry.refuse(RefusalStrings.noWorkspaceGroup(entry.id))
            }
        case .pane:
            _ = services.registry.perform("pane.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: entry.id), origin: .user))
        case .tab:
            guard services.revealTab(entry.id) else { return services.registry.refuse(TabSearchAppStrings.tabGone) }
        }
    }

    /// The groups the active window's sidebar draws, in its order.
    static func groups(_ services: AppServices) -> [PaletteNavigationGroup] {
        guard let sidebar = services.windows.active?.sidebar else { return [] }
        return sidebar.model.sections.flatMap(\.nodes).compactMap { node in
            guard case let .group(group) = node else { return nil }
            return PaletteNavigationGroup(id: group.id.rawValue, name: group.name, color: group.custom == nil ? group.color : nil,
                                          workspaceIDs: group.workspaces.map(\.id.rawValue))
        }
    }
}
