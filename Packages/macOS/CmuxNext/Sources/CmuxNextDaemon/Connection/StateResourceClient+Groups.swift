import Foundation

/// Tab groups, screen metadata and groups, and personal workspace groups as
/// v2 state mutations (`tab_group.*`, `screen.update`, `screen.move`,
/// `screen_group.*`, `workspace_group.*`, `workspace.place`). Group ids
/// are the daemon's state ids (`tgrp_…`, `sgrp_…`, `grp_…`).
extension StateResourceClient {
    /// The `id` of a group snapshot a create returns.
    public struct CreatedGroup: Decodable, Sendable, Equatable {
        public var id: String
    }

    // MARK: Tab groups

    @discardableResult
    public func createTabGroup(tabs: [ResourceID], name: String?, color: String?) async throws -> CreatedGroup {
        var params: [String: JSONValue] = ["tabs": Self.ids(tabs)]
        if let name { params["name"] = .string(name) }
        if let color { params["color"] = .string(color) }
        return try await stateMutation("tab_group.create", params, as: CreatedGroup.self)
    }

    public func updateTabGroup(_ group: String, name: String? = nil, color: String? = nil, collapsed: Bool? = nil) async throws {
        var params: [String: JSONValue] = ["tab_group": .string(group)]
        if let name { params["name"] = .string(name) }
        if let color { params["color"] = .string(color) }
        if let collapsed { params["collapsed"] = .bool(collapsed) }
        try await stateMutation("tab_group.update", params)
    }

    /// Adds tabs at `index` inside the group (the end when nil).
    public func addTabs(_ tabs: [ResourceID], toTabGroup group: String, index: Int? = nil) async throws {
        var params: [String: JSONValue] = ["tab_group": .string(group), "tabs": Self.ids(tabs)]
        if let index { params["index"] = .number(Double(max(0, index))) }
        try await stateMutation("tab_group.add_tabs", params)
    }

    public func removeTabsFromTabGroup(_ tabs: [ResourceID]) async throws {
        try await stateMutation("tab_group.remove_tabs", ["tabs": Self.ids(tabs)])
    }

    /// Moves a group to `index` of `pane` (its own pane when nil).
    public func moveTabGroup(_ group: String, toPane pane: ResourceID? = nil, index: Int) async throws {
        var params: [String: JSONValue] = ["tab_group": .string(group), "index": .number(Double(max(0, index)))]
        if let pane { params["pane_id"] = .string(pane.rawValue) }
        try await stateMutation("tab_group.move", params)
    }

    public func ungroupTabGroup(_ group: String) async throws {
        try await stateMutation("tab_group.ungroup", ["tab_group": .string(group)])
    }

    /// Closes every member tab.
    public func closeTabGroup(_ group: String) async throws {
        try await stateMutation("tab_group.close", ["tab_group": .string(group)])
    }

    // MARK: Screens

    /// Screen pin, color, and icon (`screen.update`).
    public func updateScreen(_ screen: ResourceID, pinned: Bool? = nil, color: FieldUpdate<String> = .unchanged,
                             icon: FieldUpdate<String> = .unchanged) async throws {
        var params: [String: JSONValue] = ["screen": .string(screen.rawValue)]
        if let pinned { params["pinned"] = .bool(pinned) }
        Self.field(color, into: &params, "color") { .string($0) }
        Self.field(icon, into: &params, "icon") { .string($0) }
        try await stateMutation("screen.update", params)
    }

    /// Moves a screen within its workspace; the daemon keeps pinned screens
    /// first and groups contiguous.
    public func moveScreen(_ screen: ResourceID, to index: Int) async throws {
        try await stateMutation("screen.move", ["screen": .string(screen.rawValue), "index": .number(Double(max(0, index)))])
    }

    @discardableResult
    public func createScreenGroup(screens: [ResourceID], name: String?, color: String?) async throws -> CreatedGroup {
        var params: [String: JSONValue] = ["screens": Self.ids(screens)]
        if let name { params["name"] = .string(name) }
        if let color { params["color"] = .string(color) }
        return try await stateMutation("screen_group.create", params, as: CreatedGroup.self)
    }

    // MARK: Personal workspace groups (home session)

    @discardableResult
    public func createWorkspaceGroup(name: String, room: String?, color: String?, index: Int? = nil) async throws -> CreatedGroup {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let room { params["room"] = .string(room) }
        if let color { params["color"] = .string(color) }
        if let index { params["index"] = .number(Double(max(0, index))) }
        return try await stateMutation("workspace_group.create", params, as: CreatedGroup.self)
    }

    public func updateWorkspaceGroup(_ group: String, name: String? = nil, color: FieldUpdate<String> = .unchanged,
                                     collapsed: Bool? = nil) async throws {
        var params: [String: JSONValue] = ["workspace_group": .string(group)]
        if let name { params["name"] = .string(name) }
        Self.field(color, into: &params, "color") { .string($0) }
        if let collapsed { params["collapsed"] = .bool(collapsed) }
        try await stateMutation("workspace_group.update", params)
    }

    public func deleteWorkspaceGroup(_ group: String) async throws {
        try await stateMutation("workspace_group.delete", ["workspace_group": .string(group)])
    }

    public func moveWorkspaceGroup(_ group: String, to index: Int) async throws {
        try await stateMutation("workspace_group.move", ["workspace_group": .string(group), "index": .number(Double(max(0, index)))])
    }

    /// A live workspace of this session in the personal sidebar order:
    /// its group (`.clear` ungroups) and final position.
    public func placeWorkspace(_ workspace: ResourceID, group: FieldUpdate<String> = .unchanged, index: Int? = nil) async throws {
        var params: [String: JSONValue] = ["workspace": .string(workspace.rawValue)]
        Self.field(group, into: &params, "group") { .string($0) }
        if let index { params["index"] = .number(Double(max(0, index))) }
        try await stateMutation("workspace.place", params)
    }

    /// A workspace's personal group and order in the home session: through
    /// `workspace.place` when `resource` (its public id, for a live workspace
    /// of this session on a daemon with state resources) is given, else the
    /// raw `set-personal-workspace` (workspaces of other sessions).
    public func placePersonalWorkspace(session: String, key: WorkspaceKey, resource: ResourceID?,
                                       group: FieldUpdate<WorkspaceGroupID> = .unchanged, index: Int? = nil) async throws {
        if let resource {
            let state: FieldUpdate<String> = switch group {
            case .unchanged: .unchanged
            case .clear: .clear
            case .set(let id): .set(id.rawValue)
            }
            return try await placeWorkspace(resource, group: state, index: index)
        }
        try await connection.setPersonalWorkspace(SetPersonalWorkspaceRequest(sessionID: session, workspaceKey: key, index: index, group: group))
    }
}
