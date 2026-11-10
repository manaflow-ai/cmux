import Foundation

/// The mirror's rows as the existing sidebar views draw them, so the look
/// stays the same. The reducer regroups them (cmux-layout-reducer
/// `sidebar_doc::project`, `SidebarMirror.projection`): every section that
/// is not a machine's is a layout section (Pinned first, untitled, with the
/// tile or row look it carries; custom and app sections as before), the
/// machine sections become the workspace list (one `workspaces` section
/// where the first one sits), and each machine's rows become its nodes in
/// the document's order (links, tabs and apps too). A group in Pinned or a
/// custom section is not a tile: it lists as header and member rows, drawn by
/// the list like any group (`bandGroups`, `arrange`). This maps that reply to
/// the list's own models.
public nonisolated struct SidebarDocProjection: Hashable, Sendable {
    /// One node of a machine section.
    public enum Node: Hashable, Sendable {
        case workspace(SidebarDocWorkspaceRef, item: String)
        case group(Group)
        /// A url, tab or app item: a row with the workspace row's look.
        case link(SidebarListItem)
    }

    public struct Group: Hashable, Sendable {
        public var id: String
        public var name: String
        public var color: String?
        public var icon: String?
        public var collapsed: Bool
        public var members: [SidebarDocWorkspaceRef]
        /// The document section that holds it.
        public var section: String = ""
        /// It sits in the Pinned band (Pin Group put it there): it lists above every machine
        /// section, and its header and menu read as pinned (plans/cmux-next/sidebar-ordering-DESIGN.md).
        public var pinned = false
        /// The document item ids of the workspace members, in order (`members`).
        public var memberItems: [String] = []
        /// The url, tab and app members (any item that is not a workspace or a group), in order.
        public var listed: [Listed] = []
        /// The group it sits in (a nested group); nil at the top level.
        public var parent: String?
        /// Group levels above it: 0 at the top level.
        public var depth = 0
        /// The open workspace members (rows that are not a closed one's, dimmed): the window listing one owns the group.
        public var openMembers: [SidebarDocWorkspaceRef] = []
        /// The space it was made in (`SidebarDocItem.room`); nil: made before groups carried one.
        public var room: String?

        /// Whether a window on space `room` lists this group when it lists none of its workspaces (an empty
        /// group, a kept group whose members closed): a top-level group only in its own space (spaces.md). One with no
        /// stored space is the default space's, unless an open workspace of it says otherwise (it lists where that one
        /// lists). `room` nil: no space filter (every group lists, as before spaces owned them). `spaces`: the spaces
        /// that exist; a group of one that is gone is the default space's (`SidebarDocItem.owningRoom`).
        /// A nested group (`followsParent`) lists wherever its parent lists, and the caller checks the parent. So no
        /// group lists in no space, whatever an op left stored: a top-level one always has a space that exists, and
        /// every group under it goes with it.
        public func lists(inRoom room: String?, spaces: Set<String>? = nil) -> Bool {
            guard let room, !followsParent else { return true }
            if let own = self.room { return SidebarDocItem.owningRoom(own, spaces: spaces) == room }
            return room == SidebarDocItem.defaultRoom && openMembers.isEmpty
        }

        /// A group under another group: its space is its parent's, whatever it stores (a link-only child, a New
        /// Subgroup, one nested under another space's group, one left behind when its parent moved space). Its own
        /// stored space counts again if it leaves the parent.
        public var followsParent: Bool { parent != nil }

        /// A url, tab or app member and the workspace member's item it follows (nil: first).
        public struct Listed: Hashable, Sendable {
            public var item: SidebarListItem
            public var after: String?
        }
    }

    /// The bands' sections, with the workspace list's place.
    public var layout: SidebarLayoutDocument
    /// Each machine's nodes in order, by session id.
    public var machines: [String: [Node]]
    /// The item that places each workspace (any section).
    public var items: [SidebarDocWorkspaceRef: String]
    /// The machine section of each session.
    public var machineSections: [String: String]
    /// The machine sections in the document's order (the workspace list's sections).
    public var machineOrder: [String] = []
    /// Live workspaces the document does not place yet (`sidebar.adopt`).
    public var unplaced: [SidebarDocWorkspaceRef]
    /// The groups of Pinned and custom sections, in document order, with their members.
    public var bandGroups: [Group]
    /// The machine sections made remote groups (remote-groups-DESIGN.md slice 4), by document section id.
    public var hostGroups: Set<String> = []
    /// The items whose rows draw archived: archived, or under an archived group (archiving-DESIGN.md).
    public var archived: Set<String> = []
    /// Each group's sort other than manual, by group item (the group editor's Sort).
    public var groupSorts: [String: SidebarGroupSort] = [:]
    /// The group members pinned inside their group: a sorted group keeps them first.
    public var pinnedInGroup: Set<String> = []
    /// Each group's own chats-per-project cap (0 is All), by group item; absent follows the setting.
    public var groupRowLimits: [String: Int] = [:]
    /// The rows each group's Show more revealed past its cap, by group item.
    public var groupRevealed: [String: Int] = [:]

    /// The layout item kind of a group placed in Pinned or a custom section.
    public static let groupKind = "group"

    /// The projection the mirror made in Rust (`SidebarMirror.project`), as the list's own models.
    init(wire: SidebarDocWire.Projection, revision: UInt64) {
        var sections: [LayoutSection] = []
        for projected in wire.sections {
            guard let record = projected.section?.record else {
                // The workspace list stands for the machine sections: it shows the first one's alignment and spacing
                // (a band edit of the list writes them to every machine section).
                var spacing = SectionArrangement.list
                if let like = projected.like?.record {
                    spacing.align = like.arrangement.align
                    spacing.gap = like.arrangement.gap
                }
                sections.append(LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, look: .list,
                                              arrangement: spacing, content: .workspaces))
                continue
            }
            var section = Self.section(record)
            section.items = (projected.items ?? []).map { band in
                var item = Self.layoutItem(band.item.record)
                if let room = band.room { item.room = room }
                return item
            }
            sections.append(section)
        }
        layout = SidebarLayoutDocument(revision: revision, sections: sections)
        machines = wire.machines.mapValues { $0.map(Self.node) }
        items = Dictionary(wire.items.map { ($0.ref, $0.item) }, uniquingKeysWith: { _, last in last })
        machineSections = wire.machineSections
        machineOrder = wire.machineOrder
        unplaced = wire.unplaced
        bandGroups = wire.bandGroups.map(Self.group)
        hostGroups = Set(wire.hostGroups)
        archived = Set(wire.archived)
        groupSorts = wire.groupSorts.compactMapValues { SidebarGroupSort(rawValue: $0) }
        pinnedInGroup = Set(wire.pinnedInGroup)
        groupRowLimits = wire.groupRowLimits ?? [:]
        groupRevealed = wire.groupRevealed ?? [:]
    }

    private static func node(_ node: SidebarDocWire.Node) -> Node {
        switch node {
        case let .workspace(ref, item): .workspace(ref, item: item)
        case let .group(group): .group(Self.group(group))
        case let .link(item): .link(listItem(item.record))
        }
    }

    private static func group(_ wire: SidebarDocWire.Group) -> Group {
        var group = Group(id: wire.id, name: wire.name, color: wire.color, icon: wire.icon, collapsed: wire.collapsed,
                          members: wire.members.map(\.ref), section: wire.section, pinned: wire.pinned ?? false)
        group.memberItems = wire.members.map(\.item)
        group.listed = wire.listed.map { Group.Listed(item: listItem($0.item.record), after: $0.after) }
        group.parent = wire.parent
        group.depth = wire.depth
        group.openMembers = wire.openMembers
        group.room = wire.room
        return group
    }

    static func section(_ record: SidebarDocSection) -> LayoutSection {
        var contribution: String?
        if case .app(let name) = record.kind { contribution = name }
        return LayoutSection(id: LayoutSectionID(record.id), title: record.title, showsTitle: record.showsTitle, region: record.region,
                             look: record.look, arrangement: record.arrangement, room: record.room, maxRows: record.maxRows,
                             content: contribution == nil ? .items : .app, contribution: contribution)
    }

    /// A non-workspace item as a list row: its title (a link's page title,
    /// the stored label, else its reference) and a link's page icon address.
    static func listItem(_ item: SidebarDocItem) -> SidebarListItem {
        let ref = ref(item.body, id: item.id)
        let title = label(item) ?? ref.value // a built-in or app takes its own title on the main actor (`arrange`)
        var iconAddress = item.iconURL
        if iconAddress == nil, case .url(let page, _) = item.body, let url = URL(string: page), let host = url.host, let scheme = url.scheme,
           ["http", "https"].contains(scheme.lowercased()) {
            let shownHost = host.contains(":") ? "[\(host)]" : host // an IPv6 host takes brackets
            iconAddress = "\(scheme)://\(shownHost)\(url.port.map { ":\($0)" } ?? "")/favicon.ico" // the site's own until the item stores one
        }
        return SidebarListItem(id: item.id, ref: ref, title: title, iconAddress: iconAddress)
    }

    static func layoutItem(_ item: SidebarDocItem) -> LayoutItem {
        LayoutItem(id: LayoutItemID(item.id), ref: ref(item.body, id: item.id), showsLabel: item.showsLabel, span: item.span, label: label(item))
    }

    /// The layout ref of an item body; a workspace by its qualified id `<session>:<ws_…>`.
    static func ref(_ body: SidebarDocBody, id: String) -> LayoutItemRef {
        switch body {
        case .workspace(let ref): .workspace("\(ref.sessionID):\(ref.workspaceID)")
        case .group: LayoutItemRef(kind: groupKind, value: id)
        case .builtin(let value): LayoutItemRef(kind: LayoutItemRef.builtInKind, value: value)
        case .app(let value): .app(value)
        case .url(let value, _): .url(value)
        case .tab(let value): .tab(value)
        case .room(let value): .room(value)
        case .savedGroup(let value): .savedGroup(value)
        case .ref(let kind, let value): LayoutItemRef(kind: kind, value: value)
        case .other(let kind): LayoutItemRef(kind: kind, value: id)
        }
    }

    private static func label(_ item: SidebarDocItem) -> String? {
        switch item.body {
        case .group(let name, _, _, _): name
        case .url(_, let title): title ?? item.label
        default: item.label
        }
    }

    /// The machine section's id of a workspace list position, else the
    /// layout section's id.
    public func docSection(machine session: String?) -> String? {
        session.flatMap { machineSections[$0] }
    }
}

extension SidebarDocStore {
    /// The projection of the current document over `live` (memoized per
    /// version, live set and the order of the unplaced live workspaces
    /// (`SidebarDocProjectionCache`), so a rebuild costs one `project` call and
    /// a daemon reorder of placed workspaces costs none).
    public func projection(live: [SidebarDocWorkspaceRef]) -> SidebarDocProjection? {
        guard isActive else { return nil }
        if let cached = projectionCache, cached.answers(version: version, live: live) { return cached.projection }
        // The mirror's shown document holds the pending changes (a rename, a new group, a Chief dragged in before its echo).
        // Of its pending adds, only a workspace, the Chief (with the groups it puts back) and a new group draw before
        // their echo.
        guard var wire = projected(SidebarViewRequest(live: live)) else { return nil }
        let drawn = shownRecords
        let chief = Set(pendingChief.flatMap(\.add.ancestors).map(\.id) + [SidebarLayoutDocument.chiefItemID.rawValue])
        wire.keep { drawn.items[$0] != nil || chief.contains($0) }
        let projection = SidebarDocProjection(wire: wire, revision: records.revision)
        projectionCache = SidebarDocProjectionCache(version: version, live: live, projection: projection)
        return projection
    }

    /// Rebuilds `shown` over `live` (the App's observation of the
    /// document's version and the live workspaces); asks the daemon to
    /// place live workspaces it lacks.
    /// `connectedRemotes`: the other machines' sessions connected now. A
    /// placed workspace of one of them that left the live set while its
    /// machine stayed connected closed there: the client removes its placement
    /// (the home daemon closes its own machine's workspaces itself).
    public func show(live: [SidebarDocWorkspaceRef], connectedRemotes: Set<String> = []) {
        let previous = lastLiveProjection
        let next = projection(live: live)
        shownVersion = version
        if next != shown { shown = next }
        if let next, !next.unplaced.isEmpty { adopt(next.unplaced) }
        let now = Set(live)
        let stillConnected = connectedRemotes.intersection(lastConnectedRemotes)
        let closed = lastLive.subtracting(now).filter { stillConnected.contains($0.sessionID) && previous?.items[$0] != nil }
        (lastLive, lastConnectedRemotes) = (now, connectedRemotes)
        lastLiveProjection = next
        guard isActive, !closed.isEmpty else { return }
        // Forward precise item deletions, which the pinned app FFI already supports.
        // Its legacy `close` operation also prunes ancestors and makes the header blink.
        let records = shownRecords
        let ops: [[String: Any]] = closed.sorted { ($0.sessionID, $0.workspaceID) < ($1.sessionID, $1.workspaceID) }
            .compactMap { ref in
                guard let id = previous?.items[ref], let item = records.items[id], item.body.workspace == ref,
                      let section = records.sections[item.section], !section.keepsClosed else { return nil }
                return ["op": "item.delete", "id": id]
            }
        send(ops: ops, title: Self.moveTitle, undoable: false)
    }

    /// The target that puts moved items where `index` (counted without
    /// them) falls among `siblings` (item ids in shown order): before the
    /// sibling there, after the last one, or first.
    public static func target(section: String, parent: String? = nil, index: Int, siblings: [String], moving: Set<String>) -> SidebarDocTarget {
        let staying = siblings.filter { !moving.contains($0) }
        if index < staying.count, index >= 0 { return SidebarDocTarget(section: section, parent: parent, before: staying[index]) }
        if let last = staying.last { return SidebarDocTarget(section: section, parent: parent, after: last) }
        return SidebarDocTarget(section: section, parent: parent, index: 0)
    }
}
