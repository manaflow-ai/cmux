import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings

/// Variant B of workspace auto-naming (`workspaces.autoName.variant` =
/// `persist`, hq#1957): the first time a workspace with the daemon's default
/// name gets a name from its front tab (a chat gets its title, a page
/// loads), it is renamed once through Rename Workspace's command
/// (`rename-workspace`; the daemon stays the one writer), so the CLI, the
/// window title and search see the name. Never again for that workspace,
/// and never one the user named (`WorkspaceAutoName.persistedName`).
///
/// Event-driven: one app-wide observation of the stores, the chat titles,
/// the setting and the variant; nothing polls. Process-wide, so two
/// windows showing one workspace send one rename. A rename changes no
/// focus or selection.
@MainActor
final class WorkspaceAutoNamer {
    /// One rename the rule asks for.
    struct Rename: Equatable, Sendable {
        var workspaceID: String
        var name: String
    }

    private weak var services: AppServices?
    /// Workspaces this app renamed or asked to rename: never again, even if
    /// the rename failed or the name went back to a default one.
    private var renamed: Set<String> = []

    init(services: AppServices) {
        self.services = services
    }

    /// Starts following the stores once settings load. The task lives as long
    /// as the app (an app-lifetime service, so it is never cancelled).
    static func start(_ services: AppServices, settings: SettingsController) {
        let namer = WorkspaceAutoNamer(services: services)
        Task { [weak settings] in
            await settings?.waitForLoad(atLeast: 1)
            for await renames in ObservationStream({ namer.pending() }) { namer.apply(renames) }
        }
    }

    /// The renames the rule asks for now, across every machine's workspaces
    /// (the Home workspace and app workspaces keep their names).
    func pending() -> [Rename] {
        guard let services else { return [] }
        let names = WorkspaceAutoNameReader(services: services)
        let rule = names.rule
        guard rule.enabled, rule.variant == .persist else { return [] }
        var renames: [Rename] = []
        for daemon in services.machines.daemons {
            for workspace in daemon.store.workspaces where workspace.kind != SidebarMapping.homeKind && workspace.app == nil {
                let front = SidebarMapping.shared.frontTab(workspace) { [services] pane in Self.selection(pane, in: workspace, services) }
                guard let name = rule.persistedName(name: workspace.name, title: workspace.title, front: front.flatMap(names.front),
                                                    alreadyRenamed: renamed.contains(workspace.id)) else { continue }
                renames.append(Rename(workspaceID: workspace.id, name: name))
            }
        }
        return renames
    }

    /// Sends each rename once, to the daemon that holds the workspace.
    func apply(_ renames: [Rename]) {
        guard let services else { return }
        for rename in renames where !renamed.contains(rename.workspaceID) {
            renamed.insert(rename.workspaceID)
            guard let (workspace, daemon) = services.machines.workspace(id: rename.workspaceID), let key = workspace.key else { continue }
            let name = rename.name
            daemon.send("rename-workspace") { _ = try await $0.renameWorkspace(key, to: name) }
        }
    }

    /// The tab the window showing `workspace` selected in `pane` (the sidebar
    /// row's front tab), else nil for the pane's default tab.
    private static func selection(_ pane: PaneModel, in workspace: WorkspaceModel, _ services: AppServices) -> String? {
        guard let window = services.windows.registry.value.owner(of: workspace.id) else { return nil }
        return services.windows.controller(for: window)?.state.selection.selection(in: pane.id)
    }
}
