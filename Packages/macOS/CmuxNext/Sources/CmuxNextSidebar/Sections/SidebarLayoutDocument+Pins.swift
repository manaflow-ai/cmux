import Foundation

/// Pinned items (PINNED-ITEMS-END-TO-END, SIDEBAR-TOP-ROWS-AND-PINS):
/// pinned workspaces are full-width rows in `sec_pinned`, a top section
/// under `sec_top` (built-in look, list, no title) that draws each pinned
/// workspace like any workspace row with its pin leading (the pinned section
/// ignores a stored grid or tiles arrangement, see `SectionFlow.mode`). It is not in
/// the defaults: the first pin adds it (`section.add`), so stored layouts
/// do not change, and it draws only while it has items (an untitled empty
/// section has no rows). "Add to Top" puts an item in `sec_top` beside
/// Home and the App Store. Each command is one op against the visible
/// document; pure (Rust `sidebar_layout_plan`), so the store's reducer is the
/// only judge.
extension SidebarLayoutDocument {
    public static let pinnedSectionID = LayoutSectionID("sec_pinned")

    /// The pinned section holding `items`.
    public static func pinnedSection(items: [LayoutItem]) -> LayoutSection {
        LayoutSection(id: pinnedSectionID, region: .top, look: .builtIn, arrangement: .list, items: items)
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
    /// (Rust `sidebar_layout_plan::pin_op`.)
    public func pinOp(_ ref: LayoutItemRef, label: String? = nil, newItem: LayoutItemID = .mint()) -> SidebarLayoutOp? {
        var request = SidebarLayoutPlanRequest("pin", document: self)
        request.ref = ref
        request.label = Self.storedLabel(label, ref: ref, id: newItem)
        request.newItem = newItem
        return SidebarLayoutReducer.plan(request)?.op
    }

    /// The ops that pin (or unpin) every ref in `refs`, each planned against the document the
    /// earlier ones leave, so they apply in order as one change (Pin on a selection). Refs
    /// already in the asked state add no op. (Rust `sidebar_layout_plan::pin_ops`.)
    public func pinOps(_ refs: [(ref: LayoutItemRef, label: String?)], pinned: Bool) -> [SidebarLayoutOp] {
        var request = SidebarLayoutPlanRequest("pin_all", document: self)
        request.pins = Self.pins(refs)
        request.pinned = pinned
        return SidebarLayoutReducer.plan(request)?.ops ?? []
    }

    /// Unpins `ref` (its tile only; a top row of the same ref stays). Nil
    /// when it is not pinned.
    public func unpinOp(_ ref: LayoutItemRef) -> SidebarLayoutOp? {
        var request = SidebarLayoutPlanRequest("unpin", document: self)
        request.ref = ref
        return SidebarLayoutReducer.plan(request)?.op
    }

    /// Adds `ref` as the last row of `sec_top` ("Add to Top"), else of the
    /// first top items section, else in a new top section. Nil when a top
    /// row already shows it (its tile does not count). `label` is stored like a tile's.
    public func addToTopOp(_ ref: LayoutItemRef, label: String? = nil, newItem: LayoutItemID = .mint(),
                           newSection: LayoutSectionID = .mint()) -> SidebarLayoutOp? {
        var request = SidebarLayoutPlanRequest("add_to_top", document: self)
        request.ref = ref
        request.label = Self.storedLabel(label, ref: ref, id: newItem)
        request.newItem = newItem
        request.newSection = newSection
        return SidebarLayoutReducer.plan(request)?.op
    }

    /// Removes `ref` from the top rows ("Remove from Top"; tiles stay).
    /// Nil when no top row shows it.
    public func removeFromTopOp(_ ref: LayoutItemRef) -> SidebarLayoutOp? {
        var request = SidebarLayoutPlanRequest("remove_from_top", document: self)
        request.ref = ref
        return SidebarLayoutReducer.plan(request)?.op
    }

    /// The op that undoes `op` applied to this document (RECOVERABLE-BY-
    /// DEFAULT, P4): a removed item (by id, or by a ref only one item has)
    /// comes back with its id at its section and index; an added item (alone, or the only item of an added
    /// section) is removed. Nil for other ops, or when `op` changes nothing.
    public func inverse(of op: SidebarLayoutOp) -> SidebarLayoutOp? {
        var request = SidebarLayoutPlanRequest("inverse", document: self)
        request.op = op
        return SidebarLayoutReducer.plan(request)?.op
    }

    /// One-time move of legacy pinned workspaces (`workspace-pin-v1`) into
    /// tiles: one op per ref in order, each planned against the document
    /// the earlier ones leave, skipping refs the top region already shows
    /// (a tile or a top row). Lossless: nothing is removed. `labels` are the
    /// workspaces' names, stored with their tiles.
    public func legacyPinMigrationOps(_ refs: [LayoutItemRef], labels: [LayoutItemRef: String] = [:]) -> [SidebarLayoutOp] {
        var request = SidebarLayoutPlanRequest("legacy_pins", document: self)
        request.pins = Self.pins(refs.map { (ref: $0, label: labels[$0]) })
        return SidebarLayoutReducer.plan(request)?.ops ?? []
    }

    /// Each ref with a freshly minted item id, its label as `LayoutItem` stores it.
    private static func pins(_ refs: [(ref: LayoutItemRef, label: String?)]) -> [SidebarLayoutPlanRequest.Pin] {
        refs.map { pin in
            let id = LayoutItemID.mint()
            return SidebarLayoutPlanRequest.Pin(ref: pin.ref, label: storedLabel(pin.label, ref: pin.ref, id: id), newItem: id)
        }
    }

    /// `label` as `LayoutItem` stores it (at most `LayoutItem.maxLabelLength` characters, nil when empty).
    private static func storedLabel(_ label: String?, ref: LayoutItemRef, id: LayoutItemID) -> String? {
        LayoutItem(id: id, ref: ref, label: label).label
    }
}

extension SidebarLayoutDocument {
    /// The first top-region item showing `ref` in `room` (the tile or top
    /// row the selection marks while the window shows that workspace).
    public func topItem(for ref: LayoutItemRef, room: String?) -> LayoutItem? {
        sections(in: .top, room: room).lazy.flatMap(\.items).first { $0.ref == ref }
    }
}
