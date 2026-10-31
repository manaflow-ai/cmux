public import CoreGraphics
import Foundation

/// The App's half of a drag on the sidebar document (sidebar-v2 S5): the
/// document item behind a list row, the machine section behind a list
/// section, the acceptance table (one FFI call per drag) and the drop (one
/// move intent). Set on `SidebarModel.docDrag` only while the document is
/// active; nil keeps the older drop resolver.
@MainActor
public struct SidebarDocDrag {
    /// The item a workspace or group row draws (the App's half); `item(_:)` answers item rows too.
    private var itemOf: (SidebarRowKey) -> String?
    /// The machine section a list section draws (the App's half); `section(_:)` answers custom sections too.
    private var sectionOf: (SectionID) -> String?
    /// What a drop of these items may do beside each row (`drag_begin`).
    public var begin: ([String]) -> [String: SidebarDocAcceptance]
    /// The drop: one move, one undo step.
    public var drop: ([String], SidebarDocTarget) -> Void
    /// The adopt ref (`session_id`, `workspace_id`, `workspace_key`) of a workspace the document does not place yet.
    public var adoptRef: (WorkspaceID) -> [String: String]?
    /// Whether another window lists this open workspace (the App's window registry): a Pinned or custom group
    /// holding it belongs to that window and is not drawn here (#25776). Without a window: every open one.
    public var listedElsewhere: (SidebarDocWorkspaceRef) -> Bool = { _ in true }

    public init(item: @escaping (SidebarRowKey) -> String?, section: @escaping (SectionID) -> String?,
                begin: @escaping ([String]) -> [String: SidebarDocAcceptance], drop: @escaping ([String], SidebarDocTarget) -> Void,
                adoptRef: @escaping (WorkspaceID) -> [String: String]? = { _ in nil }) {
        self.adoptRef = adoptRef
        itemOf = item
        sectionOf = section
        self.begin = begin
        self.drop = drop
    }

    /// The item a row draws: a workspace's, a group's, a listed document item's.
    public func item(_ key: SidebarRowKey) -> String? {
        if case .item(let id) = key { return id }
        return itemOf(key)
    }

    /// The document section a list section draws.
    public func section(_ id: SectionID) -> String? {
        if case .custom(let section) = id { return section }
        return sectionOf(id)
    }

    /// The items a drag payload moves, in order; nil when one has no item.
    public func items(_ payload: DragPayload) -> [String]? {
        let keys: [SidebarRowKey] = switch payload {
        case .workspaces(let ids): ids.map(SidebarRowKey.workspace)
        case .group(let group): [.group(group)]
        case .item(let id): [.item(id)]
        }
        let items = keys.compactMap(item)
        return items.count == keys.count ? items : nil
    }

    /// The drag geometry over `layout`'s rows (the list as drawn without
    /// the dragged rows and the gap): one slot per workspace, group and
    /// section row; folder rows take no drop.
    public func geometry(_ layout: SidebarLayout, width: CGFloat, acceptance: [String: SidebarDocAcceptance],
                         blocks: [String: SidebarRegionLayout] = [:]) -> (SidebarDragGeometry, [String: SidebarRow]) {
        var slots: [SidebarDragGeometry.Slot] = []
        var rows: [String: SidebarRow] = [:]
        // The group header open at each depth, so a subgroup's slot names the group it sits in.
        var headerAtDepth: [Int: GroupID] = [:]
        for case var row in layout.rows {
            guard let section = section(row.section) else { continue }
            // A group's one row is its group's slot, as its header was: a drop goes before, into or after the group.
            if let header = row.standingHeader { row = header }
            let frame = CGRect(x: 0, y: row.y, width: width, height: row.height)
            switch row.key {
            case .workspace, .group, .item:
                guard let id = item(row.key) else { continue }
                var parent: String?
                var kind = SidebarDragGeometry.Slot.Kind.row
                if case let .group(group) = row.key {
                    kind = .group
                    headerAtDepth = headerAtDepth.filter { $0.key < row.depth }
                    headerAtDepth[row.depth] = group
                    parent = row.depth > 0 ? headerAtDepth[row.depth - 1].flatMap { item(.group($0)) } : nil
                } else {
                    parent = row.group.flatMap { item(.group($0)) }
                }
                slots.append(.init(key: id, item: id, section: section, parent: parent, frame: frame, kind: kind))
                rows[id] = row
            case .section, .emptySection:
                slots.append(.init(key: section, item: nil, section: section, frame: frame, kind: .section))
                rows[section] = row
            case .emptyGroup(let group):
                // Its own key, the group as item and parent: a drop goes into the group, by the group's acceptance.
                guard let id = item(.group(group)) else { continue }
                let key = "empty:" + id
                slots.append(.init(key: key, item: id, section: section, parent: id, frame: frame, kind: .emptyGroup))
                rows[key] = row
            case .block(let id):
                // A block's items: tiles and rows of its own arrangement, at their base frames.
                if let block = blocks[id] { slots += blockSlots(block, at: row.y) }
            case .folder, .status, .doneFold, .showMore:
                continue
            }
        }
        return (SidebarDragGeometry(slots: slots, acceptance: acceptance), rows)
    }

    /// The anchor target of a list position (index counted without the moved items; in a group, among its
    /// member rows: workspaces and link, tab and app items, as `SidebarRow.siblingIndex` counts them).
    public func target(_ position: DropPosition, moving: [String], model: SidebarModel) -> SidebarDocTarget? {
        anchoredTarget(position, moving: moving, model: model)?.target
    }

    /// ``target(_:moving:model:)`` and the adopt ref of its anchor when the document this client holds does not
    /// place that row yet.
    ///
    /// Every row the list shows counts, as the position counts it. A workspace row with no item here takes the
    /// item id its adopt gives it (`SidebarDocStore.adoptedID`, the id the daemon uses), and `adopt` names it when
    /// it is the anchor, so the move sends its adopt first. Leaving such a row out of the count moved the position
    /// past it: Move to Top over rows the client had no item for landed right above the first group.
    public func anchoredTarget(_ position: DropPosition, moving: [String], model: SidebarModel) -> (target: SidebarDocTarget, adopt: [[String: String]])? {
        guard let section = section(position.section), let shown = model.section(position.section) else { return nil }
        var pending: [String: [String: String]] = [:]
        func workspaceItem(_ id: WorkspaceID) -> String? {
            if let placed = item(.workspace(id)) { return placed }
            guard let ref = adoptRef(id), let session = ref["session_id"], let workspace = ref["workspace_id"] else { return nil }
            let adopted = SidebarDocStore.adoptedID(SidebarDocWorkspaceRef(sessionID: session, workspaceID: workspace))
            pending[adopted] = ref
            return adopted
        }
        let siblings: [String] = if let group = position.group {
            (model.group(group)?.members ?? []).compactMap { member in
                switch member {
                case .workspace(let workspace): workspaceItem(workspace.id)
                case .item(let listed): listed.id
                }
            }
        } else {
            shown.nodes.compactMap { node in
                switch node {
                case .workspace(let workspace): workspaceItem(workspace.id)
                case .group(let group): group.id.rawValue
                case .item(let listed): listed.id
                }
            }
        }
        var target = SidebarDocStore.target(section: section, parent: position.group?.rawValue, index: position.index, siblings: siblings,
                                            moving: Set(moving))
        if position.group == nil { target = Self.topLevelAnchor(target, siblings: siblings, nested: Self.nestedGroups(shown), moving: Set(moving)) }
        let adopt = (target.before ?? target.after).flatMap { pending[$0] }.map { [$0] } ?? []
        return (target, adopt)
    }

    /// The groups in `section` that sit in another group (nested groups list flat, after their parent).
    static func nestedGroups(_ section: SidebarSection) -> Set<String> {
        Set(section.nodes.compactMap { node in
            if case let .group(group) = node, group.parent != nil { group.id.rawValue } else { nil }
        })
    }

    /// `target` with its anchor moved off a nested group: a top-level slot counts the section's
    /// rows flat, so the slot before a subgroup (or after the last row, when that is a subgroup)
    /// named the subgroup as a top-level sibling, a move the document refuses. Such a slot is the
    /// gap before the next top-level row, or after the last one.
    static func topLevelAnchor(_ target: SidebarDocTarget, siblings: [String], nested: Set<String>, moving: Set<String>) -> SidebarDocTarget {
        guard let anchor = target.before ?? target.after, nested.contains(anchor) else { return target }
        let staying = siblings.filter { !moving.contains($0) }
        if target.before != nil, let start = staying.firstIndex(of: anchor),
           let next = staying[start...].first(where: { !nested.contains($0) }) {
            return SidebarDocTarget(section: target.section, before: next)
        }
        guard let last = staying.last(where: { !nested.contains($0) }) else { return SidebarDocTarget(section: target.section, index: 0) }
        return SidebarDocTarget(section: target.section, after: last)
    }

    /// Where Move to Top (or a list reorder) sends workspace rows the document does not place when their
    /// list section has no document section here (a machine the client holds no section for yet): `index` of
    /// that machine's section, `sec_m_<session>`, which the rows' adopt (sent first) makes. Nil unless every
    /// moving row is a live workspace of one session with no item, outside a group.
    public func unplacedTarget(_ position: DropPosition, moving ids: [WorkspaceID]) -> SidebarDocTarget? {
        guard position.group == nil, !ids.isEmpty, ids.allSatisfy({ item(.workspace($0)) == nil }) else { return nil }
        let sessions = Set(ids.compactMap { adoptRef($0)?["session_id"] })
        guard sessions.count == 1, let session = sessions.first, !session.isEmpty,
              ids.allSatisfy({ adoptRef($0)?["session_id"] != nil }) else { return nil }
        return SidebarDocTarget(section: SidebarDocStore.machineSectionPrefix + session, index: position.index)
    }

    /// The anchor target of a band position: `index` among `section`'s items in `layout`.
    public static func target(_ section: LayoutSectionID, index: Int, moving: [String], layout: SidebarLayoutDocument) -> SidebarDocTarget {
        let siblings = layout.section(section)?.items.map(\.id.rawValue) ?? []
        return SidebarDocStore.target(section: section.rawValue, index: index, siblings: siblings, moving: Set(moving))
    }

    /// Keyboard reorder while the list is filtered: the selection moves next
    /// to its visible neighbour above (`up`) or below, as one anchored move.
    public func keyboardMove(_ ids: [WorkspaceID], up: Bool, model: SidebarModel) -> Bool {
        guard let matches = model.filterMatches else { return false }
        let moving = Set(ids)
        let visible = model.sections.flatMap { section in section.nodes.flatMap { node in
            node.workspaces.filter { matches.contains($0.id) || moving.contains($0.id) }.map { (section.id, node, $0.id) }
        } }
        guard let first = visible.firstIndex(where: { moving.contains($0.2) }),
              let last = visible.lastIndex(where: { moving.contains($0.2) }) else { return false }
        let neighbour = up ? visible[..<first].last : visible[(last + 1)...].first
        guard let (sectionID, node, id) = neighbour, let section = section(sectionID), let anchor = item(.workspace(id)) else { return false }
        let items = ids.compactMap { item(.workspace($0)) }
        guard items.count == ids.count else { return false }
        var parent: String?
        if case .group(let group) = node { parent = group.id.rawValue }
        drop(items, up ? SidebarDocTarget(section: section, parent: parent, before: anchor) : SidebarDocTarget(section: section, parent: parent, after: anchor))
        return true
    }

    /// The list's drop look for `hit` (the gap or the highlighted group).
    public static func display(_ hit: SidebarDragGeometry.Hit, row: SidebarRow) -> DropTarget {
        switch (hit.zone, row.key) {
        case (.into, .group(let group)):
            return .intoGroup(group)
        case (_, .section(let section)), (_, .emptySection(let section)):
            return .position(DropPosition(section: section, index: 0))
        case (_, .group):
            return .position(DropPosition(section: row.section, index: row.siblingIndex + (hit.zone == .after ? 1 : 0)))
        default:
            return .position(DropPosition(section: row.section, group: row.group, index: row.siblingIndex + (hit.zone == .after ? 1 : 0)))
        }
    }
}
