public import CmuxNextDesign
import Foundation

/// A collapsible group of workspaces inside a machine section.
public nonisolated struct SidebarGroup: Identifiable, Hashable, Sendable {
    public var id: GroupID
    public var name: String
    /// The palette token; grey (none) when `custom` is set.
    public var color: GroupColor
    /// A color picked outside the palette, as `#RRGGBB` (cx-25az): it draws instead of `color`.
    public var custom: String?
    public var isCollapsed: Bool
    /// Pinned (saved) group: it survives closing its workspaces, like a
    /// saved tab group, and clicking it while empty reopens it.
    public var isPinned: Bool
    /// The group's icon (`workspace-group-icon-v1`), drawn in its label
    /// before the name; nil draws the name alone.
    public var icon: WorkspaceIcon?
    public var workspaces: [SidebarWorkspace]
    /// The group's url, tab and app members (sidebar-v2), each placed after
    /// the workspace member it follows in the document (`members`).
    public var items: [SidebarGroupItem] = []
    /// The group this group sits in (`workspace-group-nest-v1`); nil at the
    /// top level. A nested group is its own node, after its parent's node in
    /// the section; the layout draws it under the parent.
    public var parent: GroupID?
    /// The workspaces of the groups nested in this one (every level), for
    /// the activity and unread totals a collapsed header shows.
    public var nestedWorkspaces: [SidebarWorkspace] = []

    /// Every member in document order: the workspaces, with each item after
    /// the workspace it follows (first when it follows none; last when that
    /// workspace is not in `workspaces`, e.g. closed or in another room).
    public var members: [SidebarGroupMember] {
        guard !items.isEmpty else { return workspaces.map(SidebarGroupMember.workspace) }
        var after: [WorkspaceID: [SidebarListItem]] = [:]
        var first: [SidebarListItem] = [], last: [SidebarListItem] = []
        let present = Set(workspaces.map(\.id))
        for entry in items {
            if let anchor = entry.after {
                if present.contains(anchor) { after[anchor, default: []].append(entry.item) } else { last.append(entry.item) }
            } else {
                first.append(entry.item)
            }
        }
        var members = first.map(SidebarGroupMember.item)
        for workspace in workspaces {
            members.append(.workspace(workspace))
            members += (after[workspace.id] ?? []).map(SidebarGroupMember.item)
        }
        return members + last.map(SidebarGroupMember.item)
    }

    /// Sets `workspaces` and `items` so `members` reads `members` back.
    public mutating func setMembers(_ members: [SidebarGroupMember]) {
        var workspaces: [SidebarWorkspace] = [], items: [SidebarGroupItem] = []
        for member in members {
            switch member {
            case let .workspace(ws): workspaces.append(ws)
            case let .item(item): items.append(SidebarGroupItem(item: item, after: workspaces.last?.id))
            }
        }
        (self.workspaces, self.items) = (workspaces, items)
    }

    /// `name`, or the localized default for a group made without one (an
    /// onto-drop, "group selected"): the home daemon refuses an empty name.
    public static func named(_ name: String) -> String {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return name }
        return String(localized: "sidebar.group.newName", defaultValue: "New Group", bundle: .module)
    }

    public init(
        id: GroupID,
        name: String,
        color: GroupColor = .grey,
        custom: String? = nil,
        isCollapsed: Bool = false,
        isPinned: Bool = false,
        icon: WorkspaceIcon? = nil,
        parent: GroupID? = nil,
        workspaces: [SidebarWorkspace]
    ) {
        self.parent = parent
        self.isPinned = isPinned
        self.icon = icon
        self.id = id
        self.name = name
        self.color = color
        self.custom = custom
        self.isCollapsed = isCollapsed
        self.workspaces = workspaces
    }

    /// What the header and the members' line draw with.
    public var tint: GroupTint {
        get { custom.flatMap(GroupTint.init(wire:)) ?? .palette(color) }
        set {
            color = newValue.token
            if case .custom = newValue { custom = newValue.wire } else { custom = nil }
        }
    }

    /// Aggregate unread count shown on a collapsed group header.
    public var unreadTotal: Int {
        (workspaces + nestedWorkspaces).reduce(0) { total, ws in
            switch ws.unread {
            case .none: total
            case .dot: total + 1
            case let .count(n): total + n
            }
        }
    }

    /// Strongest activity among children, shown on a collapsed group header.
    public var aggregateActivity: StatusIndicatorState {
        StatusStack.resolve((workspaces + nestedWorkspaces).map { StatusReport(id: $0.id.rawValue, source: .explicit, state: $0.activity, style: $0.activityStyle) }).state
    }
}

nonisolated extension SidebarGroup {
    /// The ids of the groups nested in `id` (every level) among `groups`.
    public static func descendants(of id: GroupID, in groups: some Collection<SidebarGroup>) -> [GroupID] {
        var out: [GroupID] = []
        var frontier = [id]
        while let parent = frontier.popLast(), out.count < groups.count {
            let children = groups.filter { $0.parent == parent && $0.id != id && !out.contains($0.id) }.map(\.id)
            out += children
            frontier += children
        }
        return out
    }
}

nonisolated extension [SidebarNode] {
    /// The nodes with each group's ``SidebarGroup/nestedWorkspaces`` filled from the groups nested in it.
    public func fillingNestedWorkspaces() -> [SidebarNode] {
        let groups = compactMap { node -> SidebarGroup? in if case let .group(group) = node { group } else { nil } }
        guard groups.contains(where: { $0.parent != nil }) else { return self }
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return map { node in
            guard case var .group(group) = node else { return node }
            group.nestedWorkspaces = SidebarGroup.descendants(of: group.id, in: groups).flatMap { byID[$0]?.workspaces ?? [] }
            return .group(group)
        }
    }
}

/// A url, tab or app item inside a group (sidebar-v2): what its member row
/// draws and the workspace member it follows (nil: first in the group).
public nonisolated struct SidebarGroupItem: Hashable, Sendable {
    public var item: SidebarListItem
    public var after: WorkspaceID?

    public init(item: SidebarListItem, after: WorkspaceID? = nil) {
        self.item = item
        self.after = after
    }
}

/// One member row of a group, in document order (`SidebarGroup.members`).
public nonisolated enum SidebarGroupMember: Hashable, Sendable {
    case workspace(SidebarWorkspace)
    case item(SidebarListItem)
}

/// A child of a section: a loose workspace or a group.
public nonisolated enum SidebarNode: Identifiable, Hashable, Sendable {
    case workspace(SidebarWorkspace)
    case group(SidebarGroup)
    /// A sidebar document item that is not a workspace or group (a link, a
    /// tab, an app), drawn as a row with the workspace row's look.
    case item(SidebarListItem)

    public nonisolated enum ID: Hashable, Sendable {
        case workspace(WorkspaceID)
        case group(GroupID)
        case item(String)
    }

    public var id: ID {
        switch self {
        case let .workspace(ws): .workspace(ws.id)
        case let .group(group): .group(group.id)
        case let .item(item): .item(item.id)
        }
    }

    /// Every workspace in this node, in visual order.
    public var workspaces: [SidebarWorkspace] {
        switch self {
        case let .workspace(ws): [ws]
        case let .group(group): group.workspaces
        case .item: []
        }
    }

    /// Every url, tab and app row of this node: a listed item, or a group's member items.
    public var listedItems: [SidebarListItem] {
        switch self {
        case .workspace: []
        case let .group(group): group.items.map(\.item)
        case let .item(item): [item]
        }
    }
}

/// A url, tab or app item of the sidebar document listed as a row
/// (sidebar-v2): its document item id, what a click runs, and what it draws
/// (the favicon at `iconAddress` when known, regular-weight title, no kind glyph).
public nonisolated struct SidebarListItem: Hashable, Sendable {
    public var id: String
    public var ref: LayoutItemRef
    public var title: String
    /// The page icon address of a link (stored on the item, else the site's own).
    public var iconAddress: String?

    public init(id: String, ref: LayoutItemRef, title: String, iconAddress: String? = nil) {
        self.id = id
        self.ref = ref
        self.title = title
        self.iconAddress = iconAddress
    }
}
