import CmuxMobileModel
import CmuxMobileTransport
import Foundation

/// The Mac's workspace groups on the linked Mac, with the `cmux.protocol/2`
/// operations its own sidebar sends on a Mac with personal order
/// (cmux-next `StateResourceClient+Groups`; cmux-next-ios/SECURITY.md "Workspace groups"):
/// - Move Workspace to Group… / Remove Workspace from Group: `workspace.place
///   {workspace: ws_…, group | null}`.
/// - Move Workspace to New Group: `workspace_group.create {name, color, room}`,
///   then `workspace.place` into it.
/// - Rename Group…, its color, Collapse / Expand: `workspace_group.update`.
/// - Ungroup Workspaces / Delete Group: `workspace_group.delete` (the
///   workspaces stay; the Mac keeps the group in its closed history).
/// cmux-mobile-host forwards an update, delete or place only for a group of this
/// Mac's workspaces and a live workspace of this Mac.
extension LiveWorkspaceCreationBackend: WorkspaceGroupBackend {
    public func groups(on macID: String) -> [MacWorkspaceGroup] {
        guard canManage(on: macID), macID == sync.macID, let registry = sync.tree?.registryID,
              let arrangement = sync.arrangement, arrangement.rows != nil else { return [] }
        return arrangement.ownGroups(registryID: registry)
    }

    public func place(_ workspace: Workspace, in group: MacWorkspaceGroup?) async throws {
        let client = try daemonClient(workspace.macID)
        try await resource(client, "workspace.place", Self.placeParams(workspace, group: group?.id), key: "cmux-next-ios-group-place")
        await settleGroups()
    }

    public func moveToNewGroup(_ workspace: Workspace, name: String, color: WorkspaceColor) async throws {
        let client = try daemonClient(workspace.macID)
        _ = try Self.placeParams(workspace, group: nil)
        let room = sync.tree?.registryID.flatMap { registry in sync.arrangement?.room(forWorkspace: workspace.id, registryID: registry) }
            ?? SidebarArrangement.defaultRoom
        let created = try await resource(client, "workspace_group.create", ["name": name, "color": color.rawValue, "room": room],
                                         key: "cmux-next-ios-group-create")
        guard let id = Self.createdGroupID(created) else {
            throw WorkspaceCreationError("The Mac made the group but didn't say which one")
        }
        do {
            try await resource(client, "workspace.place", Self.placeParams(workspace, group: id), key: "cmux-next-ios-group-place")
        } catch {
            // The group was made for this workspace only: an empty group must not stay behind.
            _ = try? await resource(client, "workspace_group.delete", ["workspace_group": id], key: "cmux-next-ios-group-delete")
            throw error
        }
        await settleGroups()
    }

    public func updateGroup(_ group: MacWorkspaceGroup, on macID: String, name: String?, color: WorkspaceColor?, collapsed: Bool?) async throws {
        let client = try daemonClient(macID)
        var params: [String: Any] = ["workspace_group": group.id]
        if let name { params["name"] = name }
        if let color { params["color"] = color.rawValue }
        if let collapsed { params["collapsed"] = collapsed }
        try await resource(client, "workspace_group.update", params, key: "cmux-next-ios-group-update")
        await settleGroups()
    }

    public func deleteGroup(_ group: MacWorkspaceGroup, on macID: String) async throws {
        let client = try daemonClient(macID)
        try await resource(client, "workspace_group.delete", ["workspace_group": group.id], key: "cmux-next-ios-group-delete")
        await settleGroups()
    }

    /// `workspace.place` params: the workspace's resource id and its group (null: none).
    nonisolated static func placeParams(_ workspace: Workspace, group: String?) throws -> [String: Any] {
        guard let resource = workspace.resourceID else {
            throw WorkspaceCreationError("This Mac's cmux doesn't group workspaces from a phone yet", isForPerson: true)
        }
        return ["workspace": resource, "group": group.map { $0 as Any } ?? NSNull()]
    }

    /// The new group's id in a `workspace_group.create` response (`result.value.id`).
    nonisolated static func createdGroupID(_ response: [String: Any]) -> String? {
        let result = response["result"] as? [String: Any]
        let value = result?["value"] as? [String: Any] ?? result
        return value?["id"] as? String
    }

    /// The Mac's groups and order again, then the list.
    private func settleGroups() async {
        sync.invalidateArrangement()
        _ = try? await sync.listNow()
    }
}
