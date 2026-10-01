import Foundation

/// Screen metadata (pin, color, icon) and screen groups, the daemon's
/// `cmux.protocol/2` state resources (cmux-tui/spec/resource-api-v2.md
/// "State resources"). The raw `list-workspaces` tree does not carry them:
/// `DaemonConnection.snapshot()` reads `screen.list` and `screen_group.list`
/// and `decorate` lays them over the raw screens by public screen id. Every
/// state change emits `tree-changed`, so the next snapshot picks it up.
public struct ScreenStateSnapshot: Sendable, Hashable {
    /// One screen's state fields (the `extra` map of a v2 screen value).
    public struct Meta: Sendable, Hashable, Decodable {
        public var pinned: Bool
        public var color: String?
        public var icon: String?
        public var group: ScreenGroupID?

        public init(pinned: Bool = false, color: String? = nil, icon: String? = nil, group: ScreenGroupID? = nil) {
            self.pinned = pinned
            self.color = color
            self.icon = icon
            self.group = group
        }

        enum CodingKeys: String, CodingKey {
            case pinned, color, icon
            case group = "screen_group_id"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            color = try c.decodeIfPresent(String.self, forKey: .color)
            icon = try c.decodeIfPresent(String.self, forKey: .icon)
            group = try c.decodeIfPresent(ScreenGroupID.self, forKey: .group)
        }
    }

    /// A v2 screen value (`screen.list`); only its id and state fields.
    public struct Screen: Sendable, Hashable, Decodable {
        public var id: ResourceID
        public var meta: Meta

        public init(id: ResourceID, meta: Meta) {
            self.id = id
            self.meta = meta
        }

        enum CodingKeys: String, CodingKey { case id, extra }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(ResourceID.self, forKey: .id)
            meta = try c.decodeIfPresent(Meta.self, forKey: .extra) ?? Meta()
        }
    }

    /// A v2 screen group (`screen_group.list`, `sgrp_…`).
    public struct Group: Sendable, Hashable, Decodable {
        public var id: ScreenGroupID
        public var workspaceID: ResourceID?
        public var name: String
        public var color: String?
        public var collapsed: Bool
        /// Member public screen ids.
        public var screenIDs: [ResourceID]

        public init(id: ScreenGroupID, workspaceID: ResourceID? = nil, name: String = "", color: String? = nil,
                    collapsed: Bool = false, screenIDs: [ResourceID] = []) {
            self.id = id
            self.workspaceID = workspaceID
            self.name = name
            self.color = color
            self.collapsed = collapsed
            self.screenIDs = screenIDs
        }

        enum CodingKeys: String, CodingKey {
            case id, name, color, collapsed
            case workspaceID = "workspace_id"
            case screenIDs = "screen_ids"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(ScreenGroupID.self, forKey: .id)
            workspaceID = try c.decodeIfPresent(ResourceID.self, forKey: .workspaceID)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            color = try c.decodeIfPresent(String.self, forKey: .color)
            collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
            screenIDs = try c.decodeIfPresent([ResourceID].self, forKey: .screenIDs) ?? []
        }
    }

    public var screens: [ResourceID: Meta]
    public var groups: [Group]

    public init(screens: [Screen] = [], groups: [Group] = []) {
        self.screens = Dictionary(screens.map { ($0.id, $0.meta) }, uniquingKeysWith: { _, last in last })
        self.groups = groups
    }

    /// Sets `screen`'s pin, color, icon, and group from the state.
    public func decorate(_ screen: inout ScreenSnapshot) {
        let meta = screen.resourceID.flatMap { screens[$0] } ?? Meta()
        screen.pinned = meta.pinned
        screen.color = meta.color
        screen.icon = meta.icon
        screen.group = meta.group
    }

    /// Decorates every screen of `workspace` and rebuilds its group runs in
    /// screen order.
    public func decorate(_ workspace: inout WorkspaceSnapshot) {
        for index in workspace.screens.indices { decorate(&workspace.screens[index]) }
        workspace.screenGroups = runs(workspace.screens.map { ($0.resourceID, $0.id) })
    }

    /// Group runs over `screens` (public id, handle) in workspace order.
    public func runs(_ screens: [(ResourceID?, ScreenID)]) -> [ScreenGroupSnapshot] {
        groups.compactMap { group in
            let members = screens.enumerated().filter { _, screen in screen.0.map(group.screenIDs.contains) ?? false }
            guard let start = members.first?.offset else { return nil }
            return ScreenGroupSnapshot(id: group.id, name: group.name, color: group.color, collapsed: group.collapsed,
                                       start: start, screens: members.map { $0.element.1 })
        }.sorted { $0.start < $1.start }
    }

    public func decorate(_ tree: inout DaemonTree) {
        for index in tree.workspaces.indices { decorate(&tree.workspaces[index]) }
    }
}
