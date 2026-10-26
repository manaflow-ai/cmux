import CmuxNextIPC
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
        try await stateMutation(Self.tabGroupCreateRequest(tabs: tabs, name: name, color: color), as: CreatedGroup.self)
    }

    static func tabGroupCreateRequest(tabs: [ResourceID], name: String?, color: String?) -> V2TabGroupCreateRequest {
        V2TabGroupCreateRequest(color: color, name: name, tabs: tabs.map { V2TabID(rawValue: $0.rawValue) })
    }

    /// `icon` (`tab-group-icon-v1`): `.clear` sends `null`, which removes it.
    public func updateTabGroup(_ group: String, name: String? = nil, color: String? = nil, collapsed: Bool? = nil,
                               icon: FieldUpdate<String> = .unchanged) async throws {
        try await stateMutation(Self.tabGroupUpdateRequest(group, name: name, color: color, collapsed: collapsed, icon: icon))
    }

    static func tabGroupUpdateRequest(_ group: String, name: String?, color: String?, collapsed: Bool?,
                                      icon: FieldUpdate<String>) -> V2TabGroupUpdateRequest {
        V2TabGroupUpdateRequest(collapsed: collapsed, color: color, icon: icon.resourceField { $0 }, name: name, tabGroup: group)
    }

    /// Adds tabs at `index` inside the group (the end when nil).
    public func addTabs(_ tabs: [ResourceID], toTabGroup group: String, index: Int? = nil) async throws {
        try await stateMutation(Self.tabGroupAddTabsRequest(tabs, group: group, index: index))
    }

    static func tabGroupAddTabsRequest(_ tabs: [ResourceID], group: String, index: Int?) -> V2TabGroupAddTabsRequest {
        V2TabGroupAddTabsRequest(index: index.map(Self.index), tabGroup: group, tabs: tabs.map { V2TabID(rawValue: $0.rawValue) })
    }

    public func removeTabsFromTabGroup(_ tabs: [ResourceID]) async throws {
        try await stateMutation(V2TabGroupRemoveTabsRequest(tabs: tabs.map { V2TabID(rawValue: $0.rawValue) }))
    }

    /// Moves a group to `index` of `pane` (its own pane when nil).
    public func moveTabGroup(_ group: String, toPane pane: ResourceID? = nil, index: Int) async throws {
        try await stateMutation(Self.tabGroupMoveRequest(group, pane: pane, index: index))
    }

    static func tabGroupMoveRequest(_ group: String, pane: ResourceID?, index: Int) -> V2TabGroupMoveRequest {
        V2TabGroupMoveRequest(index: Self.index(index), paneID: pane.map { V2PaneID(rawValue: $0.rawValue) }, tabGroup: group)
    }

    public func ungroupTabGroup(_ group: String) async throws {
        try await stateMutation(V2TabGroupUngroupRequest(tabGroup: group))
    }

    /// Closes every member tab.
    public func closeTabGroup(_ group: String) async throws {
        try await stateMutation(V2TabGroupCloseRequest(tabGroup: group))
    }

    // MARK: Screens

    /// Screen pin, color, and icon (`screen.update`).
    public func updateScreen(_ screen: ResourceID, pinned: Bool? = nil, color: FieldUpdate<String> = .unchanged,
                             icon: FieldUpdate<String> = .unchanged) async throws {
        try await stateMutation(Self.screenUpdateRequest(screen, pinned: pinned, color: color, icon: icon))
    }

    static func screenUpdateRequest(_ screen: ResourceID, pinned: Bool?, color: FieldUpdate<String>,
                                    icon: FieldUpdate<String>) -> V2ScreenUpdateRequest {
        V2ScreenUpdateRequest(screen: selector(screen), color: color.resourceField { $0 }, icon: icon.resourceField { $0 },
                              pinned: pinned)
    }

    /// Moves a screen within its workspace; the daemon keeps pinned screens
    /// first and groups contiguous.
    public func moveScreen(_ screen: ResourceID, to index: Int) async throws {
        try await stateMutation(V2ScreenMoveRequest(screen: Self.selector(screen), index: Self.index(index)))
    }

    @discardableResult
    public func createScreenGroup(screens: [ResourceID], name: String?, color: String?) async throws -> CreatedGroup {
        try await stateMutation(Self.screenGroupCreateRequest(screens: screens, name: name, color: color), as: CreatedGroup.self)
    }

    static func screenGroupCreateRequest(screens: [ResourceID], name: String?, color: String?) -> V2ScreenGroupCreateRequest {
        V2ScreenGroupCreateRequest(color: color, name: name, screens: screens.map { V2ScreenID(rawValue: $0.rawValue) })
    }

    // MARK: Personal workspace groups (home session)

    @discardableResult
    public func createWorkspaceGroup(name: String, room: String?, color: String?, index: Int? = nil) async throws -> CreatedGroup {
        try await stateMutation(Self.workspaceGroupCreateRequest(name: name, room: room, color: color, index: index),
                                as: CreatedGroup.self)
    }

    static func workspaceGroupCreateRequest(name: String, room: String?, color: String?,
                                            index: Int?) -> V2WorkspaceGroupCreateRequest {
        V2WorkspaceGroupCreateRequest(color: color, index: index.map(Self.index), name: name, room: room)
    }

    /// `topIndex` (`personal-mixed-order-v1`): the personal row index the
    /// group shows right before; `.clear` puts it after every loose workspace.
    /// `icon` (`workspace-group-icon-v1`) and `pinned` (`workspace-group-pin-v1`).
    public func updateWorkspaceGroup(_ group: String, name: String? = nil, color: FieldUpdate<String> = .unchanged,
                                     collapsed: Bool? = nil, topIndex: FieldUpdate<Int> = .unchanged,
                                     icon: FieldUpdate<String> = .unchanged, pinned: Bool? = nil) async throws {
        try await stateMutation(Self.workspaceGroupUpdateRequest(group, name: name, color: color, collapsed: collapsed,
                                                                 topIndex: topIndex, icon: icon, pinned: pinned))
    }

    static func workspaceGroupUpdateRequest(_ group: String, name: String?, color: FieldUpdate<String>, collapsed: Bool?,
                                            topIndex: FieldUpdate<Int>, icon: FieldUpdate<String>,
                                            pinned: Bool?) -> V2WorkspaceGroupUpdateRequest {
        V2WorkspaceGroupUpdateRequest(collapsed: collapsed, color: color.resourceField { $0 }, icon: icon.resourceField { $0 },
                                      name: name, pinned: pinned, topIndex: topIndex.resourceField(Self.index),
                                      workspaceGroup: group)
    }

    public func deleteWorkspaceGroup(_ group: String) async throws {
        try await stateMutation(V2WorkspaceGroupDeleteRequest(workspaceGroup: group))
    }

    public func moveWorkspaceGroup(_ group: String, to index: Int) async throws {
        try await stateMutation(V2WorkspaceGroupMoveRequest(index: Self.index(index), workspaceGroup: group))
    }

    /// A live workspace of this session in the personal sidebar order:
    /// its group (`.clear` ungroups) and final position.
    public func placeWorkspace(_ workspace: ResourceID, group: FieldUpdate<String> = .unchanged, index: Int? = nil) async throws {
        try await stateMutation(Self.workspacePlaceRequest(workspace, group: group, index: index))
    }

    static func workspacePlaceRequest(_ workspace: ResourceID, group: FieldUpdate<String>,
                                      index: Int?) -> V2WorkspacePlaceRequest {
        V2WorkspacePlaceRequest(workspace: selector(workspace), group: group.resourceField { $0 }, index: index.map(Self.index))
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
