import CmuxNextBridge
import CmuxNextSettings
import CmuxNextWorkspaceNaming

/// The app's sources for workspace auto-naming (hq#1957, CmuxNextWorkspaceNaming).
@MainActor
struct WorkspaceAutoNameWiring {
    let services: AppServices

    /// The front-tab reader over this app's setting, pages and terminals.
    var reader: WorkspaceAutoNameReader {
        WorkspaceAutoNameReader(
            enabled: { [weak services] in services?.settings?.snapshot.sidebarSections.autoNamesWorkspaces ?? true },
            isNewTabPage: { [weak services] tab in services.map { RestoredNewTabPages.shows(tab, in: $0.agentTabs) } ?? false },
            livePage: { [weak services] tab in services?.cache.existingBrowser(tab.id).map { ($0.tab.state.title, $0.tab.state.url) } },
            incognitoTitle: { [weak services] tab in
                guard let services, services.cache.browserTabs.isIncognitoTab(tab.id) else { return nil }
                return .some(services.cache.incognitoDisplay(tab).title)
            },
            terminal: { [weak services] tab in services.map { TabMoves.nameInput(tab, services: $0) } ?? .init(kind: .terminal, userName: nil, title: nil, pageTitle: nil, url: nil, cwd: nil) })
    }

    /// Variant B's one-time rename (`WorkspaceAutoNamer`) on this Mac's daemon, once settings load.
    func start(settings: SettingsController) {
        let namer = WorkspaceAutoNamer(
            names: reader, workspaces: { [weak services] in services?.machines.local.store.workspaces ?? [] },
            selection: { [weak services] workspace, pane in
                guard let services, let window = services.windows.registry.value.owner(of: workspace.id) else { return nil }
                return services.windows.controller(for: window)?.state.selection.selection(in: pane.id)
            },
            rename: { [weak services] key, name in services?.machines.local.send("rename-workspace") { _ = try await $0.renameWorkspace(key, to: name) } })
        Task { [weak settings] in
            await settings?.waitForLoad(atLeast: 1)
            await namer.run()
        }
    }
}
