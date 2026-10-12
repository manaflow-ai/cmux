import Foundation

// Tab groups (`tab-groups-v1`, cmux-tui/spec/commands.md
// `create-tab-group` ... `close-tab-group`). Tabs are named by numeric
// surface id (the daemon also accepts `tab_...` ids). Group membership
// commands take an optional client `transaction` echoed in each member's
// `tab-changed`; `update-tab-group`, `ungroup-tab-group`, and
// `close-tab-group` take none.

/// Result of a tab-group command. Commands that return a group
/// (`create/update/add/move/reopen`) fill `group`, `pane`, `workspace`, and
/// `surfaces`. `ungroup-tab-group` and `close-tab-group` return the group id
/// only (`groupID`), plus `surfaces` or `closed`. `remove-tabs-from-tab-group`
/// returns `surfaces` and `groups`.
public struct TabGroupResult: Decodable, Sendable, Equatable {
    /// The group after the change; nil when the command returns only an id
    /// or the group disappeared.
    public var group: TabGroupSnapshot?
    /// The group the command acted on, whichever form the response used.
    public var groupID: TabGroupID?
    public var pane: PaneID?
    public var workspace: WorkspaceHandle?
    /// Members after the change (`ungroup`: the former members).
    public var surfaces: [SurfaceID]
    /// `close-tab-group`: the closed placements.
    public var closed: [SurfaceID]
    /// `remove-tabs-from-tab-group`: the groups the tabs left.
    public var groups: [TabGroupID]

    @available(*, deprecated, message: "Not in the tab-groups-v1 result; always nil")
    public var screen: ScreenID? { nil }
    @available(*, deprecated, message: "Not in the tab-groups-v1 result; always nil")
    public var key: WorkspaceKey? { nil }
    @available(*, deprecated, message: "Not in the tab-groups-v1 result; always nil")
    public var changed: Bool? { nil }
    @available(*, deprecated, message: "Not in the tab-groups-v1 result; always nil")
    public var undoable: Bool? { nil }

    enum CodingKeys: String, CodingKey { case group, pane, workspace, surfaces, closed, groups }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? c.decode(TabGroupID.self, forKey: .group) {
            group = nil
            groupID = id
        } else {
            group = try c.decodeIfPresent(TabGroupSnapshot.self, forKey: .group)
            groupID = group?.id
        }
        pane = try c.decodeIfPresent(PaneID.self, forKey: .pane)
        workspace = try c.decodeIfPresent(WorkspaceHandle.self, forKey: .workspace)
        surfaces = try c.decodeIfPresent([SurfaceID].self, forKey: .surfaces) ?? []
        closed = try c.decodeIfPresent([SurfaceID].self, forKey: .closed) ?? []
        groups = try c.decodeIfPresent([TabGroupID].self, forKey: .groups) ?? []
    }
}

/// Every live group with its pane, in the `Pane.tab_groups` shape.
public struct ListTabGroupsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var groups: [TabGroupSnapshot]
    }
    public static let command = "list-tab-groups"
    public static let requiredCapability: String? = DaemonCapabilities.shared.tabGroups
    public init() {}
}
