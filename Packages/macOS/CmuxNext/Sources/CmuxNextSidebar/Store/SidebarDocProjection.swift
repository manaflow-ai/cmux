import Foundation

/// The mirror's rows as the existing sidebar views draw them, so the look
/// stays the same: every section that is not a machine's becomes a layout
/// section (Pinned first, untitled, with the tile or row look it carries;
/// custom and app sections as before), the machine sections become the
/// workspace list (one `workspaces` section where the first one sits), and
/// each machine's rows become its nodes in the document's order (links,
/// tabs and apps too). A group in Pinned or a custom section is not a tile:
/// it lists as header and member rows, drawn by the list like any group
/// (`bandGroups`, `arrange`). Pure: it only regroups rows the reducer ordered.
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

        /// A url, tab or app member and the workspace member's item it follows (nil: first).
        public struct Listed: Hashable, Sendable {
            public var item: SidebarListItem
            public var after: String?
        }

        mutating func add(_ id: String, _ item: SidebarDocItem) {
            if let ref = item.body.workspace {
                members.append(ref)
                memberItems.append(id)
            } else if SidebarDocProjection.listsAsRow(item.body) {
                listed.append(Listed(item: SidebarDocProjection.listItem(item), after: memberItems.last))
            }
        }
    }

    /// An item that lists as a row (a link, a tab, an app, ...): not a workspace or a group.
    static func listsAsRow(_ body: SidebarDocBody) -> Bool {
        switch body {
        case .workspace, .group: false
        case .url, .tab, .app, .builtin, .room, .savedGroup, .ref, .other: true
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

    /// The layout item kind of a group placed in Pinned or a custom section.
    public static let groupKind = "group"

    public init(rows: [SidebarDocRow], records: SidebarDocRecords, revision: UInt64) {
        var sections: [LayoutSection] = []
        var machines = SidebarDocMachineNodes()
        var items: [SidebarDocWorkspaceRef: String] = [:]
        var machineSections: [String: String] = [:]
        var unplaced: [SidebarDocWorkspaceRef] = []
        var placedList = false
        var sectionIndex: [String: Int] = [:]
        var bandGroups: [Group] = []
        var machineOrder: [String] = []
        var archivedItems: Set<String> = []

        for row in rows {
            if row.archived, let id = row.item { archivedItems.insert(id) }
            // A live machine without a stored section yet (`sec_m_<session>`) still lists, unplaced.
            let record = records.sections[row.section]
                ?? SidebarDocSection(id: row.section, kind: .machine(session: row.ref?.sessionID ?? SidebarDocWire.Section.session(fromID: row.section)))
            if let session = record.session {
                if machineSections[session] == nil { machineOrder.append(record.id) }
                machineSections[session] = record.id
                if !placedList {
                    placedList = true
                    // The workspace list stands for the machine sections: it shows the first one's alignment and spacing
                    // (a band edit of the list writes them to every machine section).
                    var spacing = SectionArrangement.list
                    spacing.align = record.arrangement.align
                    spacing.gap = record.arrangement.gap
                    sections.append(LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, look: .list,
                                                  arrangement: spacing, content: .workspaces))
                }
                Self.place(row, session: session, records: records, into: &machines, items: &items, unplaced: &unplaced)
                continue
            }
            if sectionIndex[record.id] == nil {
                sectionIndex[record.id] = sections.count
                sections.append(Self.section(record))
            }
            guard let id = row.item, let item = Self.item(of: row, id: id, records: records), let index = sectionIndex[record.id] else { continue }
            if let ref = item.body.workspace { items[ref] = id } // members of a pinned group too: they list once
            if case let .group(name, color, icon, collapsed) = item.body {
                // A nested group (remote-groups-DESIGN.md R1) lists after its parent, with its own members.
                var group = Group(id: id, name: name, color: color, icon: icon, collapsed: collapsed, members: [], section: record.id,
                                  pinned: record.kind == .pinned)
                group.parent = row.depth > 0 ? row.parent ?? item.parent : nil
                group.depth = row.depth
                bandGroups.append(group)
            } else if row.depth > 0, let parent = row.parent ?? item.parent,
                      let at = bandGroups.lastIndex(where: { $0.id == parent }) {
                bandGroups[at].add(id, item) // a workspace, link, tab or app member: a member row in the list
                if let ref = item.body.workspace, !row.dimmed { bandGroups[at].openMembers.append(ref) }
            } else if row.depth == 0 {
                sections[index].items.append(Self.layoutItem(item))
            }
        }
        if !placedList {
            sections.append(LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, look: .list, content: .workspaces))
        }
        layout = SidebarLayoutDocument(revision: revision, sections: sections)
        self.machines = machines.nodes()
        self.items = items
        self.machineSections = machineSections
        self.machineOrder = machineOrder
        self.unplaced = unplaced
        self.bandGroups = bandGroups
        archived = archivedItems
        hostGroups = Set(records.sections.values.filter(\.hostGroup).map(\.id))
    }

    private static func place(_ row: SidebarDocRow, session: String, records: SidebarDocRecords, into machines: inout SidebarDocMachineNodes,
                              items: inout [SidebarDocWorkspaceRef: String], unplaced: inout [SidebarDocWorkspaceRef]) {
        guard let id = row.item, let item = item(of: row, id: id, records: records) else {
            if let ref = row.ref { unplaced.append(ref) }
            return
        }
        switch item.body {
        case .workspace(let ref):
            items[ref] = id
            if let parent = row.parent ?? item.parent, row.depth > 0 {
                machines.add(id, item, toGroup: parent, session: session)
            } else {
                machines.append(.workspace(ref, item: id), session: session)
            }
        case let .group(name, color, icon, collapsed):
            var group = Group(id: id, name: name, color: color, icon: icon, collapsed: collapsed, members: [], section: row.section)
            group.parent = row.depth > 0 ? row.parent ?? item.parent : nil
            group.depth = row.depth
            machines.append(group, session: session)
        case .url, .tab, .app, .builtin, .room, .savedGroup, .ref, .other:
            // Any item may sit in a machine section: it lists as a row, a group's member row inside a group.
            guard row.depth > 0 else { return machines.append(.link(Self.listItem(item)), session: session) }
            guard let parent = row.parent ?? item.parent else { return }
            machines.add(id, item, toGroup: parent, session: session)
        }
    }

    /// Row `row`'s item `id`: its confirmed record, else, for a workspace row that only a pending change places (the
    /// app's adopt and move of a new workspace into its slot, before the daemon's echo), the workspace item the row
    /// names. The rows come from the mirror, pending changes included, and the records only from confirmed batches: a
    /// row without a record listed as unplaced, first in its machine section under `top`, until the echo moved it to
    /// its slot (Austin 2026-10-21: Cmd-N inside a group drew the row at the top, then moved it into the group).
    private static func item(of row: SidebarDocRow, id: String, records: SidebarDocRecords) -> SidebarDocItem? {
        if let item = records.items[id] { return item }
        guard let ref = row.ref else { return nil }
        return SidebarDocItem(id: id, section: row.section, parent: row.depth > 0 ? row.parent : nil, body: .workspace(ref))
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
    /// (`SidebarDocProjectionCache`), so a rebuild costs one `view` call and
    /// a daemon reorder of placed workspaces costs none).
    public func projection(live: [SidebarDocWorkspaceRef]) -> SidebarDocProjection? {
        guard isActive else { return nil }
        if let cached = projectionCache, cached.answers(version: version, live: live) { return cached.projection }
        guard let rows = rows(SidebarViewRequest(live: live)) else { return nil }
        let projection = SidebarDocProjection(rows: rows, records: records, revision: records.revision)
        projectionCache = SidebarDocProjectionCache(version: version, live: live, projection: projection)
        return projection
    }

    /// Rebuilds `shown` over `live` (the App's observation of the
    /// document's version and the live workspaces); asks the daemon to
    /// place live workspaces it lacks.
    /// `connectedRemotes`: the other machines' sessions connected now. A
    /// placed workspace of one of them that left the live set while its
    /// machine stayed connected closed there: the client sends `close` for
    /// it (the home daemon closes its own machine's workspaces itself).
    public func show(live: [SidebarDocWorkspaceRef], connectedRemotes: Set<String> = []) {
        let previous = shown
        let next = projection(live: live)
        shownVersion = version
        if next != shown { shown = next }
        if let next, !next.unplaced.isEmpty { adopt(next.unplaced) }
        let now = Set(live)
        let stillConnected = connectedRemotes.intersection(lastConnectedRemotes)
        let closed = lastLive.subtracting(now).filter { stillConnected.contains($0.sessionID) && previous?.items[$0] != nil }
        (lastLive, lastConnectedRemotes) = (now, connectedRemotes)
        guard isActive, !closed.isEmpty else { return }
        let refs = closed.sorted { ($0.sessionID, $0.workspaceID) < ($1.sessionID, $1.workspaceID) }
            .map { ["session_id": $0.sessionID, "workspace_id": $0.workspaceID] }
        send(ops: [["op": "close", "refs": refs]], title: Self.moveTitle, undoable: false)
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
