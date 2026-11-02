public import Foundation

/// Band edits (`SidebarLayoutOp`: the section and item actions of menus,
/// the palette, the CLI and a section header drag) as document ops while
/// the document is active. With `sidebar-doc-v1` the bands are document
/// sections, so their edits go to the document (one `sidebar.apply`, one
/// undo step), never to the older `sidebar_layout` owner: the older owner
/// would confirm a change the document never sees, and it would vanish.
/// A workspace lives in one place: adding it to a section moves its item
/// there (or adopts it there), and removing it from a band unpins it.
extension SidebarDocStore {
    /// Why a band edit has no document op.
    public enum LayoutOpGap: Error, Hashable, Sendable {
        /// An edit the document has no op for (a non-workspace item into the workspace list).
        case unsupported
        /// The workspace list stands for the machine sections: it cannot move, be removed, be renamed or be scoped to a space.
        case workspaceList
        case unknownItem
        /// An edit the layout's own rules refuse (an app section without a valid contribution or with
        /// items, a second workspace list), as the older layout owner refuses it.
        case rejected(SidebarLayoutReject)
    }

    /// The document ops of `ops`, in order, planned over `layout` (the
    /// bands as shown). Anchors follow the earlier ops of the same list,
    /// so several adds at consecutive indexes keep their order.
    public func docOps(for ops: [SidebarLayoutOp], layout: SidebarLayoutDocument) throws(LayoutOpGap) -> [[String: Any]] {
        var planner = LayoutOpPlanner(records: drawnRecords, confirmed: settledRecords, shown: shown, layout: layout,
                                      room: newItemRoom())
        var out: [[String: Any]] = []
        for op in ops { out += try planner.ops(for: op) }
        return out
    }

    /// The `item.update` ops that store the acting window's space `room` on `items` moving into `section`: a link,
    /// tab or app in Pinned draws only in its space (`extra.room`), and one with none stored reads as the default
    /// space's (spaces.md), so a move into Pinned from another band stores it in the same change, as `item.add` does.
    /// Only a link, tab or app stores one (`SidebarDocBody.belongsToASpace`); nor does a move into another band,
    /// one with no space, or an item `records` does not confirm yet (the daemon would refuse the whole change).
    static func roomOps(moving items: [String], into section: String, room: String?, records: SidebarDocRecords) -> [[String: Any]] {
        guard section == pinnedSection, let room else { return [] }
        return items.compactMap { id -> [String: Any]? in
            guard let record = records.items[id], record.body.belongsToASpace,
                  (record.room ?? SidebarDocItem.defaultRoom) != room else { return nil }
            return ["op": "item.update", "id": id, "patch": ["room": room]]
        }
    }

    /// Space `from` was deleted into space `to` (Delete Space's `moveTo`): every item it owned (a Pinned link, tab or
    /// app, a group) moves to `to` in one change, with no undo step (the delete has none). With no `to` nothing moves:
    /// an item of a gone space reads as the default space's (`SidebarDocItem.owningRoom`) and returns if it comes back.
    public func moveSpace(_ from: String, into to: String) {
        let ops = Self.spaceOps(from: from, into: to, records: records)
        if !ops.isEmpty { send(ops: ops, title: Self.moveTitle, undoable: false) }
    }

    /// Group `group` moved to space `room` (Move Group to Space): its stored space follows, so it stays in `room` once
    /// no workspace of it lists there (an empty group lists only in its own space).
    public func moveGroup(_ group: GroupID, toSpace room: String) {
        _ = (group, room)
    }

    /// The ops of `moveSpace`: a group's space is its `profile` (`group.update`), a link's, tab's or app's `extra.room`.
    static func spaceOps(from: String, into to: String, records: SidebarDocRecords) -> [[String: Any]] {
        _ = (from, to, records)
        return []
    }

    /// Sends `ops` as one document change titled `title`. Throws when an op
    /// has no document form (`LayoutOpGap`, nothing is sent) or the change is
    /// refused at once (`SidebarDocSendRefusal`).
    public func send(layout ops: [SidebarLayoutOp], over layout: SidebarLayoutDocument, title: String, undoable: Bool) throws {
        let docOps = try docOps(for: ops, layout: layout)
        guard !docOps.isEmpty else { return }
        try sendChecked(ops: docOps, title: title, undoable: undoable)
    }
}

/// Plans document ops for band edits, keeping the band's item order as
/// the earlier ops of one list change it.
@MainActor
private struct LayoutOpPlanner {
    /// The records as drawn: a pending Chief too (it moves and comes off before its echo).
    let records: SidebarDocRecords
    /// The confirmed records: an edit of an item's own fields waits for its echo (a pending Chief's record is only its row).
    let confirmed: SidebarDocRecords
    let shown: SidebarDocProjection?
    let layout: SidebarLayoutDocument
    /// The space a Pinned item is made in or moved into Pinned in (`SidebarDocStore.newItemRoom`).
    let room: String?
    /// The top-level item ids of each band section in shown order, as the planned ops leave them.
    var siblings: [String: [String]]
    typealias Gap = SidebarDocStore.LayoutOpGap

    init(records: SidebarDocRecords, confirmed: SidebarDocRecords, shown: SidebarDocProjection?, layout: SidebarLayoutDocument,
         room: String? = nil) {
        self.room = room
        self.records = records
        self.confirmed = confirmed
        self.shown = shown
        self.layout = layout
        siblings = Dictionary(layout.sections.map { ($0.id.rawValue, $0.items.map(\.id.rawValue)) }, uniquingKeysWith: { a, _ in a })
    }

    private static let workspaces = SidebarLayoutDocument.workspacesSectionID

    mutating func ops(for op: SidebarLayoutOp) throws(Gap) -> [[String: Any]] {
        switch op {
        case let .sectionAdd(section, index):
            switch section.content {
            case .items: break
            // The workspace list is exactly one section (L1): the machine sections stand for it.
            case .workspaces: throw .rejected(.workspacesRequired)
            // An app section (`<app id>#<section id>`) is a document section of kind app; it holds no items.
            case .app:
                guard section.owningAppID != nil, let contribution = section.contribution,
                      !contribution.hasSuffix("#") else { throw .rejected(.invalidContribution) }
                guard section.items.isEmpty else { throw .rejected(.itemsNotAllowed) }
                guard records.sections[section.id.rawValue] == nil else { return [] }
                return [sectionAdd(section, index: index, kind: ["type": "app", "contribution": contribution])]
            }
            // A section added with its first items (Add to Top, Pin into a new Pinned): the items follow it.
            // A section the document already has (Pinned, shown only when it holds something) takes just the items.
            var out: [[String: Any]] = []
            if records.sections[section.id.rawValue] == nil {
                out.append(sectionAdd(section, index: index))
            }
            for item in section.items { out += try add(item, to: section.id, index: Int.max) }
            return out
        case let .sectionUpdate(id, patch):
            // The workspace list is every machine section: only how its rows look applies to each one.
            if id == Self.workspaces, patch.title != nil || patch.room != nil || patch.showsTitle != nil { throw .workspaceList }
            var wire: [String: Any] = [:]
            if let title = patch.title { wire["title"] = Self.update(title) }
            if let showsTitle = patch.showsTitle { wire["shows_title"] = showsTitle }
            if let look = patch.look { wire["look"] = look.rawValue }
            if let arrangement = patch.layout { wire["arrangement"] = arrangement.rawValue }
            if let columns = patch.columns { wire["columns"] = Self.update(columns) }
            if let align = patch.align { wire["align"] = align.rawValue }
            if let gap = patch.gap { wire["gap"] = Self.update(gap) }
            if let maxRows = patch.maxRows { wire["max_rows"] = Self.update(maxRows) }
            if let room = patch.room { wire["room"] = Self.update(room) }
            guard !wire.isEmpty else { return [] }
            let ids = id == Self.workspaces ? (shown?.machineOrder ?? []) : [id.rawValue]
            return ids.map { ["op": "section.update", "id": $0, "patch": wire] }
        case let .sectionMove(id, region, index):
            guard id != Self.workspaces else { throw .workspaceList }
            return [["op": "section.move", "id": id.rawValue, "place": sectionPlace(id, region: region, index: index)]]
        case let .sectionRemove(id):
            guard id != Self.workspaces else { throw .workspaceList }
            return [["op": "section.remove", "id": id.rawValue]]
        case let .itemAdd(item, section, index):
            return try add(item, to: section, index: index)
        case let .itemMove(id, section, index):
            guard let record = records.items[id.rawValue] else { throw .unknownItem }
            if section == Self.workspaces { return backToMachine(record) }
            let move: [[String: Any]] = [["op": "move", "items": [record.id], "to": target(section.rawValue, index: index, moving: record.id)]]
            return move + SidebarDocStore.roomOps(moving: [record.id], into: section.rawValue, room: room, records: confirmed)
        case let .itemRemove(id):
            guard let record = records.items[id.rawValue] else { throw .unknownItem }
            return remove(record)
        case let .itemRemoveRef(ref):
            // Every item with the ref, in any section and at any depth (a link listed in a machine section too).
            let matching = records.items.values.filter { SidebarDocProjection.ref($0.body, id: $0.id) == ref }
            guard !matching.isEmpty else { return [] }
            // A workspace has one item: out of a band it goes back to its machine section at its place
            // (the document's item.remove_ref would drop the item, and the workspace would draw at the section's end).
            if let workspace = matching.first(where: { $0.body.workspace != nil }) { return remove(workspace) }
            // A group or an unknown body has no document ref (the client names it by item id): remove it by id.
            if matching.contains(where: { record in
                if case .group = record.body { return true }
                if case .other = record.body { return true }
                return false
            }) {
                return matching.sorted(by: { $0.id < $1.id }).flatMap { drop($0.id, op: ["op": "item.remove", "id": $0.id]) }
            }
            // Anything else: the document's own op removes every item that shows the ref, in one change. It also
            // removes a group it leaves empty, which the planner does not follow: it must be the batch's last op.
            let gone = Set(matching.map(\.id))
            for key in siblings.keys { siblings[key]?.removeAll { gone.contains($0) } }
            return [["op": "item.remove_ref", "ref": ["kind": ref.kind, "value": ref.value]]]
        case let .itemUpdate(id, showsLabel):
            guard confirmed.items[id.rawValue] != nil else { throw .unknownItem }
            return [["op": "item.update", "id": id.rawValue, "patch": ["shows_label": showsLabel]]]
        case .reset:
            // The default sections again; the daemon's inverse makes it one undo step. The planner does not follow
            // the reset (records and shown stay as they were): it must be the batch's last op.
            siblings = [:]
            return [["op": "reset"]]
        }
    }

    /// `section.add` of `section` as a document section of `kind` (a custom section unless named).
    private mutating func sectionAdd(_ section: LayoutSection, index: Int, kind: [String: String] = ["type": "custom"]) -> [String: Any] {
        var wire: [String: Any] = ["id": section.id.rawValue, "kind": kind, "shows_title": section.showsTitle,
                                   "region": section.region.rawValue, "look": section.look.rawValue,
                                   "arrangement": section.arrangement.layout.rawValue,
                                   "align": section.arrangement.align.rawValue]
        if let gap = section.arrangement.gap { wire["gap"] = gap }
        if let title = section.title { wire["title"] = title }
        if let columns = section.arrangement.columns { wire["columns"] = columns }
        if let maxRows = section.maxRows { wire["max_rows"] = maxRows }
        if let room = section.room { wire["room"] = room }
        siblings[section.id.rawValue] = []
        return ["op": "section.add", "section": wire, "place": sectionPlace(section.id, region: section.region, index: index)]
    }

    /// An item into a band. A workspace has one place: its item moves there
    /// (or is adopted there when the document does not place it yet).
    private mutating func add(_ item: LayoutItem, to section: LayoutSectionID, index: Int) throws(Gap) -> [[String: Any]] {
        if item.ref.kind == LayoutItemRef.workspaceKind {
            guard let ref = Self.workspaceRef(item.ref.value) else { throw .unknownItem }
            // A pending-only placement (no confirmed record) is adopted again, so this change does not depend on it.
            if let placed = shown?.items[ref].flatMap({ records.items[$0] == nil ? nil : $0 }) ?? records.item(for: ref)?.id {
                if section == Self.workspaces {
                    guard let record = records.items[placed] else { return [] }
                    return backToMachine(record)
                }
                return [["op": "move", "items": [placed], "to": target(section.rawValue, index: index, moving: placed)]]
            }
            let wireRef: [String: Any] = ["session_id": ref.sessionID, "workspace_id": ref.workspaceID]
            if section == Self.workspaces { return [["op": "adopt", "refs": [wireRef]]] }
            let id = SidebarDocStore.adoptedID(ref)
            return [["op": "adopt", "refs": [wireRef], "to": target(section.rawValue, index: index, moving: id)]]
        }
        guard section != Self.workspaces else { throw .unsupported }
        var wire: [String: Any] = ["id": item.id.rawValue, "body": Self.body(item), "shows_label": item.showsLabel]
        if let span = item.span { wire["span"] = span }
        // A link, tab or app pinned in one space is that space's (spaces.md); other bands are not per space.
        if section == SidebarLayoutDocument.pinnedSectionID, item.ref.belongsToASpace, let room = item.room ?? room { wire["extra"] = ["room": room] }
        return [["op": "item.add", "item": wire, "to": target(section.rawValue, index: index, moving: item.id.rawValue)]]
    }

    /// A band item out of its band: a workspace or group goes back to its
    /// machine section (unpin); any other item is removed.
    private mutating func remove(_ record: SidebarDocItem) -> [[String: Any]] {
        if records.sections[record.section]?.session != nil { return [] } // already in its machine section
        return record.body.workspace != nil || record.body.isGroup ? backToMachine(record) : drop(record.id, op: ["op": "item.remove", "id": record.id])
    }

    private mutating func backToMachine(_ record: SidebarDocItem) -> [[String: Any]] {
        if records.sections[record.section]?.session != nil { return [] }
        return drop(record.id, op: ["op": "unpin", "items": [record.id]])
    }

    private mutating func drop(_ id: String, op: [String: Any]) -> [[String: Any]] {
        for key in siblings.keys { siblings[key]?.removeAll { $0 == id } }
        return [op]
    }

    /// Where an item lands at `index` (counted without it) of a band
    /// section: before the item shown there, else the section's end. The
    /// planned order takes the item at once.
    private mutating func target(_ section: String, index: Int, moving: String) -> [String: Any] {
        for key in siblings.keys { siblings[key]?.removeAll { $0 == moving } }
        var list = siblings[section] ?? []
        var to: [String: Any] = ["section": section]
        if index >= 0, index < list.count {
            to["before"] = list[index]
            list.insert(moving, at: index)
        } else {
            list.append(moving)
        }
        siblings[section] = list
        return to
    }

    /// Where a section lands among its region's sections (counted without
    /// it, as the bands show them). The workspace list stands for the
    /// machine sections; it is the first of them, so an index up to it
    /// counts the same in the document.
    private func sectionPlace(_ id: LayoutSectionID, region: SidebarRegion, index: Int) -> [String: Any] {
        var place: [String: Any] = ["region": region.rawValue]
        let others = layout.sections.filter { $0.region == region && $0.id != id }
        guard index >= 0, index < others.count else { return place }
        let anchor = others[index].id
        if anchor != Self.workspaces {
            place["before"] = anchor.rawValue
        } else if let first = shown?.machineOrder.first {
            place["before"] = first // the first machine section in the document's order
        } else {
            place["index"] = index
        }
        return place
    }

    /// `<session>:<ws_…>` -> a document workspace ref.
    static func workspaceRef(_ value: String) -> SidebarDocWorkspaceRef? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let session = String(value[..<colon]), workspace = String(value[value.index(after: colon)...])
        return session.isEmpty || workspace.isEmpty ? nil : SidebarDocWorkspaceRef(sessionID: session, workspaceID: workspace)
    }

    /// The document body of a non-workspace layout item.
    static func body(_ item: LayoutItem) -> [String: Any] {
        let value = item.ref.value
        switch item.ref.kind {
        case LayoutItemRef.builtInKind: return ["type": "builtin", "id": value]
        case LayoutItemRef.appKind: return ["type": "app", "id": value]
        case LayoutItemRef.urlKind:
            var body: [String: Any] = ["type": "url", "url": value]
            if let label = item.label { body["title"] = label }
            return body
        case LayoutItemRef.tabKind: return ["type": "tab", "ref": value]
        case LayoutItemRef.roomKind: return ["type": "room", "id": value]
        case LayoutItemRef.savedGroupKind: return ["type": "saved_group", "id": value]
        default: return ["type": "ref", "kind": item.ref.kind, "value": value]
        }
    }

    /// A patch field: its value, or null to clear it.
    static func update<Value>(_ update: OptionalUpdate<Value>) -> Any {
        update.value.map { $0 as Any } ?? NSNull()
    }
}
