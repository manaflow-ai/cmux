public import CmuxNextDesign
import Foundation

/// A collapsible group of workspaces inside a machine section.
public nonisolated struct SidebarGroup: Identifiable, Hashable, Sendable {
    public var id: GroupID
    public var name: String
    /// The palette token; grey when `custom` is set.
    public var color: GroupColor
    /// A color picked outside the palette, as `#RRGGBB` (cx-25az), or `none` for a group with no
    /// color (`GroupTint.none`): it draws instead of `color`.
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
    /// The group this one sits in (a nested group, remote-groups-DESIGN.md R1); nil at the top level.
    /// A section lists a tree in document order: a group, then its subgroups.
    public var parent: GroupID?
    /// Group levels above this one: 0 at the top level.
    public var depth = 0
    /// Archived in the sidebar document: its header draws dimmed (its members too). Set by `arrange`.
    public var isArchived = false
    /// The machine a remote group stands for (``SidebarSection/wrappedAsHostGroup()``): its header is
    /// a group's, with the machine's mark and status dot (``SidebarHostGroupLook``); nil for every other group.
    public var machine: SidebarMachine?
    /// How a remote group's header draws its machine (the gallery sets the others).
    public var hostLook: SidebarHostGroupLook = .trailingMarkAndDot

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
        workspaces: [SidebarWorkspace]
    ) {
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
            switch newValue {
            case .custom, .none: custom = newValue.wire
            case .palette: custom = nil
            }
        }
    }

    /// Aggregate unread count shown on a collapsed group header.
    public var unreadTotal: Int {
        workspaces.reduce(0) { total, ws in
            switch ws.unread {
            case .none: total
            case .dot: total + 1
            case let .count(n): total + n
            }
        }
    }

    /// The members' loading, the one state a group header shows by default (Lawrence 2026-10-20:
    /// "All we care about is the loading"): working or busy when any member is, else idle.
    public var loadingActivity: StatusIndicatorState {
        // A spinner: a command or page loading (busy) or an agent working; not paused, waiting or done.
        let loading = workspaces.filter { member in
            switch member.activity {
            case .busy, .working: true
            case .idle, .paused, .waiting, .error, .success: false
            }
        }
        return StatusStack.resolve(loading.map { StatusReport(id: $0.id.rawValue, source: .explicit, state: $0.activity, style: $0.activityStyle) }).state
    }

    /// The one state the group's header shows by default, open or collapsed: its members' most
    /// urgent row state, red over orange over blue (Lawrence msg 11983: "blue, orange/yellow for
    /// needs attention, and red for errors"). An error, else needs you (`waiting`), else something
    /// unread or done (`success`, the blue dot); with none of those a collapsed header shows its
    /// members' loading (``loadingActivity``, Lawrence 2026-10-20) and an open one nothing, its
    /// rows show their own spinners. Each member counts as its row draws it (`WorkspaceRowBadges`).
    /// - Parameter collapsed: Whether the header is collapsed (its members hidden).
    /// - Returns: The state the header's status glyph draws.
    public func statusRollUp(collapsed: Bool) -> StatusIndicatorState {
        // This runs while a group folds and unfolds. Constructing a WorkspaceRowBadges (and its
        // sorted temporary array) for every member made a 10,000-workspace group spend tens of
        // milliseconds configuring one header. The collapsed header only needs the highest-level
        // state, so keep the same priority as WorkspaceRowBadges.simple in one pass.
        var waiting = false
        var success = false
        var loading = false
        for workspace in workspaces {
            switch workspace.activity {
            case .error:
                return .error
            case .waiting:
                waiting = true
            case .busy, .working:
                loading = true
            case .idle, .paused, .success:
                break
            }
            if workspace.activity == .success { success = true }
            switch workspace.unread {
            case .none:
                break
            case .dot:
                success = true
            case let .count(n):
                if n > 0 { success = true }
            }
        }
        if waiting { return .waiting }
        if success { return .success }
        return collapsed && loading ? loadingActivity : .idle
    }

    /// Strongest activity among children, shown on a collapsed group header
    /// with `sidebar.detailedStatusIcons` on.
    public var aggregateActivity: StatusIndicatorState {
        StatusStack.resolve(workspaces.map { StatusReport(id: $0.id.rawValue, source: .explicit, state: $0.activity, style: $0.activityStyle) }).state
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
    /// Archived in the sidebar document: the row draws dimmed. Set by `arrange`.
    public var isArchived = false

    public init(id: String, ref: LayoutItemRef, title: String, iconAddress: String? = nil) {
        self.id = id
        self.ref = ref
        self.title = title
        self.iconAddress = iconAddress
    }
}
