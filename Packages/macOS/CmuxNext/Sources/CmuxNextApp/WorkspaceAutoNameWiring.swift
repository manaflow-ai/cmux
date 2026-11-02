import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWorkspaceNaming

/// The app's sources for workspace auto-naming (hq#1957, CmuxNextWorkspaceNaming).
@MainActor
struct WorkspaceAutoNameWiring {
    let services: AppServices
    /// The one workspace every tab the reader is asked about is in (a sidebar row's): its tabs' incognito answer is
    /// that workspace's own (`WindowManager.isIncognito(workspace:)`), not a lookup of each tab's workspace, which
    /// reads every daemon's tab list and workspace list (TYPING UNDER LOAD F6). Nil: look each tab up.
    var workspace: WorkspaceModel?

    init(services: AppServices, workspace: WorkspaceModel? = nil) {
        self.services = services
        self.workspace = workspace
    }

    /// The front-tab reader over this app's setting, pages and terminals.
    var reader: WorkspaceAutoNameReader {
        let isIncognito: @MainActor (AppServices, TabModel) -> Bool = { [workspace] services, tab in
            workspace.map { services.windows.isIncognito(workspace: $0) } ?? services.cache.browserTabs.isIncognitoTab(tab.id)
        }
        return WorkspaceAutoNameReader(
            enabled: { [weak services] in services?.settings?.snapshot.sidebarSections.autoNamesWorkspaces ?? true },
            isNewTabPage: { [weak services] tab in services.map { RestoredNewTabPages.shows(tab, in: $0.agentTabs) } ?? false },
            livePage: { [weak services] tab in services?.cache.existingBrowser(tab.id).map { ($0.tab.state.title, $0.tab.state.url) } },
            incognitoTitle: { [weak services] tab in services.flatMap { s -> String?? in isIncognito(s, tab) ? .some(s.cache.incognitoDisplay(tab).title) : nil } },
            terminal: { [weak services] tab in
                services.map { TabMoves.nameInput(tab, services: $0, incognito: tab.kind == .browser && isIncognito($0, tab)) }
                    ?? .init(kind: .terminal, userName: nil, title: nil, pageTitle: nil, url: nil, cwd: nil)
            },
            hold: services.autoNameHold,
            allowsLegacyDefaults: { [weak services] workspace in
                // By identity: `daemon(forWorkspace:)` reads the workspace list, so every row re-mapped on any workspace
                // made or closed (TYPING UNDER LOAD F6).
                guard let services, let daemon = services.machines.daemon(holding: workspace) else { return true }
                return !daemon.supports(DaemonCapability.workspaceNameSource.rawValue)
            })
    }

    /// Variant B's focused-chat naming (`WorkspaceAutoNamer`) on every daemon that
    /// serves the name-source capability, once settings load.
    func start(settings: SettingsController) {
        let namer = WorkspaceAutoNamer(
            names: reader, workspaces: { [weak services] in
                guard let services else { return [] }
                return services.machines.daemons.flatMap { daemon in
                    let identity = daemon.identity
                    return daemon.store.workspaces.map { workspace in
                        WorkspaceAutoNamer.Target(
                            machineID: daemon.machineID,
                            workspace: workspace,
                            supportsNameSource: daemon.supports(DaemonCapability.workspaceNameSource.rawValue),
                            daemonGeneration: identity?.generation,
                            nameSource: workspace.nameSource,
                            nameRevision: workspace.nameRevision)
                    }
                }
            },
            selection: { [weak services] workspace, pane in
                guard let services, let window = services.windows.registry.value.owner(of: workspace.id) else { return nil }
                return services.windows.controller(for: window)?.state.selection.selection(in: pane.id)
            },
            rename: { [weak services] target, name, maySend, onFailure in
                guard let services, target.supportsNameSource, let key = target.workspace.key,
                      let daemon = services.machines.daemon(machine: target.machineID),
                      daemon.supports(DaemonCapability.workspaceNameSource.rawValue) else { return false }
                daemon.send("auto-rename workspace", onFailure: { _ in onFailure() }) { connection in
                    guard await maySend() else { return }
                    _ = try await connection.renameWorkspace(key, to: name, source: .auto,
                                                              expectedNameRevision: target.nameRevision)
                }
                return true
            })
        Task { [weak settings] in
            await settings?.waitForLoad(atLeast: 1)
            await namer.run()
        }
    }
}
