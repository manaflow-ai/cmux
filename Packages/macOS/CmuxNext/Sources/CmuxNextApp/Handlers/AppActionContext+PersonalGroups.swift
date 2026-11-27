import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextWindowRules

/// Workspace groups when the home session serves personal state
/// (plans/cmux-next/data-model.md 1.2c): groups and membership are personal
/// rows in the home daemon; the daemons that own the workspaces are never
/// written.
extension AppActionContext {
    var personal: PersonalStore { services.machines.local.store.personal }
    var usesPersonalGroups: Bool { personal.isLoaded }

    /// The targeted personal group (target, `group` argument), else the
    /// group of the targeted or shown workspace. A target may name the group
    /// by the sidebar document item the sidebar shows it as (`itm_g_<id>`:
    /// a header's +, its editor and its menu), or by its own id.
    func personalGroup(_ invocation: ActionInvocation) throws -> WorkspaceGroupModel {
        let explicit = Self.explicitTarget([invocation.target, invocation["group"]?.targetValue], kinds: [.workspaceGroup])
        if let explicit {
            guard let group = personal.group(.init(rawValue: explicit.id)) ?? personal.group(.init(rawValue: SidebarDocStore.personalGroupID(item: explicit.id))) else {
                throw ActionFailure.notFound(RefusalStrings.noWorkspaceGroup(explicit.id))
            }
            return group
        }
        guard let workspace = scope(invocation).workspace, let id = personalGroupID(of: workspace), let group = personal.group(id) else {
            throw ActionFailure.invalidTarget(RefusalStrings.workspaceNotInGroup)
        }
        return group
    }

    /// The targeted group as the active sidebar shows it, also one not in the personal store yet (Leo: "I can't ungroup").
    func shownGroup(_ invocation: ActionInvocation) throws -> (id: CmuxNextSidebar.GroupID, personalID: String, name: String, sidebar: SidebarBridge) {
        let sidebar = try sidebar(), target = Self.explicitTarget([invocation.target, invocation["group"]?.targetValue], kinds: [.workspaceGroup])
        if let target, (try? group(invocation)) == nil,
           let shown = sidebar.model.shownGroup(target: target.id, created: { sidebar.groupEditor.created[.init(rawValue: $0)]?.rawValue }) {
            return (shown.group.id, shown.personalID, shown.group.name, sidebar)
        }
        let group = try group(invocation) // a group nobody shows is refused as before
        return (sidebar.model.groupID(personal: group.id.rawValue), group.id.rawValue, group.name, sidebar)
    }

    /// A workspace's personal group, if any.
    func personalGroupID(of workspace: WorkspaceModel) -> WorkspaceGroupID? {
        guard let qualified = WindowProfiles.qualified(workspace.id, machines: services.machines) else { return nil }
        return personal.workspace(session: qualified.session, key: qualified.key)?.group
    }

    /// The targeted group as a notification sound level (``group(_:)``'s target rules).
    func soundGroup(_ invocation: ActionInvocation) throws -> NotificationSoundScope.Group {
        let group = try group(invocation)
        return .init(id: group.id.rawValue, name: group.name)
    }

    /// The personal groups workspace `id` sits in, innermost first (its notification sound levels).
    func soundGroups(ofWorkspace id: String) -> [NotificationSoundScope.Group] {
        guard usesPersonalGroups else { return [] }
        // Notification keys keep legacy bare ids local; remote workspace ids are qualified.
        // Resolve the owning object before reading personal membership, including cloned ids.
        var membership: WorkspaceGroupID?
        for daemon in services.machines.daemons {
            // A remote workspace's rule may still sit under its legacy bare id (NotificationWorkspaceKey.ruleKey);
            // the local machine comes first, so a bare id a local workspace holds stays local.
            let remote = daemon.machineID != services.machines.local.machineID
            guard let workspace = daemon.store.workspaces.first(where: {
                NotificationWorkspaceKey.settingsKey(machine: daemon.machineID, workspace: $0.id,
                                                       localMachine: services.machines.local.machineID) == id || (remote && $0.id == id)
            }), let session = daemon.store.registryID else { continue }
            membership = personal.workspace(session: session, key: workspace.key?.rawValue ?? workspace.id)?.group
            break
        }
        guard let membership else { return [] }
        // Out through each group's parent, depth-bounded so a malformed loop cannot spin (`workspaces::group_chain`).
        let known = personal.groups
        let parents = Dictionary(known.map { ($0.id.rawValue, $0.parent?.rawValue) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(known.map { ($0.id.rawValue, $0.name) }, uniquingKeysWith: { first, _ in first })
        return WindowRules().groupChain(from: membership.rawValue, parents: parents).map { .init(id: $0, name: names[$0] ?? "") }
    }

    /// The agent names of this Mac's tabs (chat harnesses, hook-reported agents), for per-agent sounds.
    var soundAgentKinds: [String] {
        store.workspaces.flatMap { $0.screens.flatMap(\.panes).flatMap(\.tabs) }.compactMap { $0.agentSession?.harness ?? $0.agent?.agent }
    }

    /// Workspaces of every session in personal group `id`.
    func workspaces(inPersonalGroup id: WorkspaceGroupID) -> [WorkspaceModel] {
        services.machines.daemons.flatMap(\.store.workspaces).filter { personalGroupID(of: $0) == id }
    }

    /// Takes a workspace out of its personal group.
    func ungroupPersonal(_ workspace: WorkspaceModel) {
        guard let qualified = WindowProfiles.qualified(workspace.id, machines: services.machines) else { return }
        let home = services.machines.local, key = WorkspaceKey(rawValue: qualified.key)
        let resource = home.store.personalStateID(session: qualified.session, key: key)
        let life = PersonalGroupLife(machines: services.machines), placement = PersonalSidebarPlanner.Placement(session: qualified.session, key: key, resource: resource)
        // The group it leaves empty goes too (cx-rcby).
        let failed: @MainActor (ActionWorkFailure) -> Void = { [weak services] failure in
            services?.windows.active?.sidebar.resync()
            services?.registry.reportFailure(of: "removeWorkspaceFromGroup", failure)
        }
        let ending = life.emptied(by: [placement], into: nil)
        life.commit("set-personal-workspace", ending: ending,
                    recheck: { ending.filter(life.isEmptyUnpinned) }, until: life.personal.writes.claim(workspaces: [(qualified.session, key.rawValue)]), failed: failed) {
            try await $0.state.placePersonalWorkspace(session: qualified.session, key: key, resource: resource, group: .clear)
        }
    }

    /// Personal groups of the active window's room, in order.
    var roomGroups: [WorkspaceGroupModel] {
        let room = activeWindow?.state.profileID ?? .defaultProfile
        return personal.groups.filter { personal.groupRooms[$0.id] == room }.sorted { $0.index < $1.index }
    }
}
