import Foundation

/// Pinned items (PINNED-ITEMS-END-TO-END, SIDEBAR-TOP-ROWS-AND-PINS):
/// pinned workspaces are small wrapping icon tiles in `sec_pinned`, a top
/// section under `sec_top` (built-in look, grid, no title). It is not in
/// the defaults: the first pin adds it (`section.add`), so stored layouts
/// do not change, and it draws only while it has items (an untitled empty
/// section has no rows). "Add to Top" puts an item in `sec_top` beside
/// Home and the App Store. Each command is one op against the visible
/// document; pure, so the store's reducer is the only judge.
extension SidebarLayoutDocument {
    public static let pinnedSectionID = LayoutSectionID("sec_pinned")

    /// The pinned section holding `items`.
    public static func pinnedSection(items: [LayoutItem]) -> LayoutSection {
        LayoutSection(id: pinnedSectionID, region: .top, look: .builtIn, arrangement: .grid, items: items)
    }

    /// Whether `ref` is a pinned tile.
    public func isPinned(_ ref: LayoutItemRef) -> Bool {
        section(Self.pinnedSectionID)?.items.contains { $0.ref == ref } ?? false
    }

    /// Whether `ref` shows in the top region in any room (a tile or a top
    /// row), so the workspace list leaves it out.
    public func isOnTop(_ ref: LayoutItemRef) -> Bool {
        sections.contains { $0.region == .top && $0.items.contains { $0.ref == ref } }
    }

    /// The values of every `kind` reference the top region shows in `room`.
    public func topValues(kind: String, room: String?) -> Set<String> {
        Set(sections(in: .top, room: room).flatMap(\.items).filter { $0.ref.kind == kind }.map(\.ref.value))
    }

    /// Pins `ref` as the last tile: adds `sec_pinned` (under `sec_top`, else
    /// last in the top region) holding it when the section is missing. Nil
    /// when it is pinned already. `label` (the workspace's name now) is
    /// stored with the tile and drawn while the workspace is closed.
    public func pinOp(_ ref: LayoutItemRef, label: String? = nil, newItem: LayoutItemID = .mint()) -> SidebarLayoutOp? {
        guard !isPinned(ref) else { return nil }
        let item = LayoutItem(id: newItem, ref: ref, label: label)
        if section(Self.pinnedSectionID) != nil { return .itemAdd(item, section: Self.pinnedSectionID, index: Int.max) }
        let top = sections(in: .top, room: nil).map(\.id)
        let index = top.firstIndex(of: Self.topSectionID).map { $0 + 1 } ?? Int.max
        return .sectionAdd(Self.pinnedSection(items: [item]), index: index)
    }

    /// Unpins `ref` (its tile only; a top row of the same ref stays). Nil
    /// when it is not pinned.
    public func unpinOp(_ ref: LayoutItemRef) -> SidebarLayoutOp? {
        section(Self.pinnedSectionID)?.items.first { $0.ref == ref }.map { .itemRemove($0.id) }
    }

    /// Adds `ref` as the last row of `sec_top` ("Add to Top"), else of the
    /// first top items section, else in a new top section. Nil when a top
    /// row already shows it (its tile does not count). `label` is stored like a tile's.
    public func addToTopOp(_ ref: LayoutItemRef, label: String? = nil, newItem: LayoutItemID = .mint(),
                           newSection: LayoutSectionID = .mint()) -> SidebarLayoutOp? {
        guard removeFromTopOp(ref) == nil else { return nil }
        let item = LayoutItem(id: newItem, ref: ref, label: label)
        let target = section(Self.topSectionID).map(\.id)
            ?? sections.first { $0.region == .top && $0.room == nil && $0.content == .items && $0.id != Self.pinnedSectionID }?.id
        if let target { return .itemAdd(item, section: target, index: Int.max) }
        return .sectionAdd(LayoutSection(id: newSection, region: .top, look: .builtIn, items: [item]), index: 0)
    }

    /// Removes `ref` from the top rows ("Remove from Top"; tiles stay).
    /// Nil when no top row shows it.
    public func removeFromTopOp(_ ref: LayoutItemRef) -> SidebarLayoutOp? {
        sections.first { $0.region == .top && $0.id != Self.pinnedSectionID && $0.items.contains { $0.ref == ref } }?
            .items.first { $0.ref == ref }.map { .itemRemove($0.id) }
    }

    /// The op that undoes `op` applied to this document (RECOVERABLE-BY-
    /// DEFAULT, P4): a removed item (by id, or by a ref only one item has)
    /// comes back with its id at its section and index; an added item (alone, or the only item of an added
    /// section) is removed. Nil for other ops, or when `op` changes nothing.
    public func inverse(of op: SidebarLayoutOp) -> SidebarLayoutOp? {
        switch op {
        case let .itemRemove(id):
            guard let (s, i) = locate(id) else { return nil }
            return .itemAdd(sections[s].items[i], section: sections[s].id, index: i)
        case let .itemAdd(item, section, _):
            guard self.section(section)?.items.contains(where: { $0.ref == item.ref }) == false else { return nil }
            return .itemRemove(item.id)
        case let .itemRemoveRef(ref):
            let holders = sections.indices.flatMap { s in sections[s].items.indices.filter { sections[s].items[$0].ref == ref }.map { (s, $0) } }
            guard holders.count == 1, let (s, i) = holders.first else { return nil }
            return .itemAdd(sections[s].items[i], section: sections[s].id, index: i)
        case let .sectionAdd(section, _):
            guard self.section(section.id) == nil, section.items.count == 1, let item = section.items.first else { return nil }
            return .itemRemove(item.id)
        default:
            return nil
        }
    }

    /// One-time move of legacy pinned workspaces (`workspace-pin-v1`) into
    /// tiles: one op per ref in order, each planned against the document
    /// the earlier ones leave, skipping refs the top region already shows
    /// (a tile or a top row). Lossless: nothing is removed. `labels` are the
    /// workspaces' names, stored with their tiles.
    public func legacyPinMigrationOps(_ refs: [LayoutItemRef], labels: [LayoutItemRef: String] = [:]) -> [SidebarLayoutOp] {
        var document = self
        var ops: [SidebarLayoutOp] = []
        for ref in refs where !document.isOnTop(ref) {
            guard let op = document.pinOp(ref, label: labels[ref]), case .success(let next) = SidebarLayoutReducer.reduce(document, op) else { continue }
            ops.append(op)
            document = next
        }
        return ops
    }
}

extension SidebarLayoutDocument {
    /// The first top-region item showing `ref` in `room` (the tile or top
    /// row the selection marks while the window shows that workspace).
    public func topItem(for ref: LayoutItemRef, room: String?) -> LayoutItem? {
        sections(in: .top, room: room).lazy.flatMap(\.items).first { $0.ref == ref }
    }
}
