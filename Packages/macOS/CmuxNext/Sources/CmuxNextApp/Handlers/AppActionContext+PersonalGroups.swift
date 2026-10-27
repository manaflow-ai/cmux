import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextSidebar

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
        let explicit = [invocation.target, invocation["group"]?.targetValue].compactMap { $0 }.first { $0.kind == .workspaceGroup }
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
        guard usesPersonalGroups, let workspace = services.machines.daemons.lazy.flatMap(\.store.workspaces).first(where: { $0.id == id }) else { return [] }
        var groups: [NotificationSoundScope.Group] = [], next = personalGroupID(of: workspace)
        // Depth-bounded: a malformed parent loop cannot spin here.
        while let id = next, groups.count < 16, let group = personal.group(id) {
            groups.append(.init(id: id.rawValue, name: group.name))
            next = group.parent
        }
        return groups
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
        life.commit("set-personal-workspace", ending: life.emptied(by: [placement], into: nil),
                    recheck: { life.emptied(by: [placement], into: nil) }, failed: failed) {
            try await $0.state.placePersonalWorkspace(session: qualified.session, key: key, resource: resource, group: .clear)
        }
    }

    /// Personal groups of the active window's room, in order.
    var roomGroups: [WorkspaceGroupModel] {
        let room = activeWindow?.state.profileID ?? .defaultProfile
        return personal.groups.filter { personal.groupRooms[$0.id] == room }.sorted { $0.index < $1.index }
    }
}
