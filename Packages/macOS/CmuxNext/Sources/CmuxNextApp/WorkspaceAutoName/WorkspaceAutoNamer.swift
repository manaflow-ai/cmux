import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings

/// Variant B of workspace auto-naming (`workspaces.autoName.variant` =
/// `persist`, hq#1957): the first time a default-named workspace of this
/// Mac's daemon has an agent chat in front whose chat has a real title (the
/// agent's, never its first prompt), it is renamed once through Rename
/// Workspace's command (`rename-workspace`; the daemon stays the one writer),
/// so the CLI, the window title and search see the name. Terminal and page
/// titles stay live sidebar labels. Never again for that workspace, and
/// never one the user named (`WorkspaceAutoName.persistedName`).
///
/// Event-driven: one app-wide observation of the local store, the chat
/// titles, the setting and the variant; nothing polls. Process-wide, so two
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

    /// The renames the rule asks for now, among this Mac's daemon's
    /// workspaces only (a remote or Cloud workspace is never renamed, so two
    /// Macs on one daemon never race; the Home workspace and app workspaces
    /// keep their names). Only a default-named workspace whose front tab is
    /// an agent chat is read further, so a terminal's title ticks or a
    /// page's loads never wake this.
    func pending() -> [Rename] {
        guard let services else { return [] }
        let names = WorkspaceAutoNameReader(services: services)
        let rule = names.rule
        guard rule.enabled, rule.variant == .persist else { return [] }
        var renames: [Rename] = []
        for workspace in services.machines.local.store.workspaces
        where workspace.kind != SidebarMapping.homeKind && workspace.app == nil && !renamed.contains(workspace.id)
            && rule.confirmsRename(currentName: workspace.name, currentTitle: workspace.title) {
            guard let front = SidebarMapping.shared.frontTab(workspace, selectedTab: { [services] pane in Self.selection(pane, in: workspace, services) }),
                  front.agentSession != nil,
                  let name = rule.persistedName(name: workspace.name, title: workspace.title, front: names.front(front),
                                                isLocalMachine: true, alreadyRenamed: false) else { continue }
            renames.append(Rename(workspaceID: workspace.id, name: name))
        }
        return renames
    }

    /// Sends each rename once, to this Mac's daemon, unless the user named
    /// the workspace since (`confirmsRename` on its current name and title).
    /// `rename-workspace` takes no expected old name, so a rename the user
    /// sends in the same instant can still lose to this one.
    func apply(_ renames: [Rename]) {
        guard let services else { return }
        let daemon = services.machines.local
        let rule = WorkspaceAutoNameReader(services: services).rule
        for rename in renames where !renamed.contains(rename.workspaceID) {
            renamed.insert(rename.workspaceID)
            guard let workspace = daemon.store.workspaces.first(where: { $0.id == rename.workspaceID }), let key = workspace.key,
                  rule.confirmsRename(currentName: workspace.name, currentTitle: workspace.title) else { continue }
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
