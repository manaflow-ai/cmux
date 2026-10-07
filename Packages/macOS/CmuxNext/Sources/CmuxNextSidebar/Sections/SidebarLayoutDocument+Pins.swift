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
        false
    }

    /// Whether `ref` shows in the top region in any room (a tile or a top
    /// row), so the workspace list leaves it out.
    public func isOnTop(_ ref: LayoutItemRef) -> Bool {
        false
    }

    /// The values of every `kind` reference the top region shows in `room`.
    public func topValues(kind: String, room: String?) -> Set<String> {
        []
    }

    /// Pins `ref` as the last tile: adds `sec_pinned` (under `sec_top`, else
    /// last in the top region) holding it when the section is missing. Nil
    /// when it is pinned already.
    public func pinOp(_ ref: LayoutItemRef, newItem: LayoutItemID = .mint()) -> SidebarLayoutOp? {
        nil
    }

    /// Unpins `ref` (its tile only; a top row of the same ref stays). Nil
    /// when it is not pinned.
    public func unpinOp(_ ref: LayoutItemRef) -> SidebarLayoutOp? {
        nil
    }

    /// Adds `ref` as the last row of `sec_top` ("Add to Top"), else of the
    /// first top items section, else in a new top section. Nil when the top
    /// region already shows it.
    public func addToTopOp(_ ref: LayoutItemRef, newItem: LayoutItemID = .mint(), newSection: LayoutSectionID = .mint()) -> SidebarLayoutOp? {
        nil
    }

    /// Removes `ref` from the top rows ("Remove from Top"; tiles stay).
    /// Nil when no top row shows it.
    public func removeFromTopOp(_ ref: LayoutItemRef) -> SidebarLayoutOp? {
        nil
    }

    /// The op that undoes `op` applied to this document (RECOVERABLE-BY-
    /// DEFAULT, P4): a removed item (by id, or by a ref only one item has)
    /// comes back with its id at its section and index; an added item (alone, or the only item of an added
    /// section) is removed. Nil for other ops, or when `op` changes nothing.
    public func inverse(of op: SidebarLayoutOp) -> SidebarLayoutOp? {
        nil
    }

    /// One-time move of legacy pinned workspaces (`workspace-pin-v1`) into
    /// tiles: one op per ref in order, each planned against the document
    /// the earlier ones leave, skipping refs the top region already shows
    /// (a tile or a top row). Lossless: nothing is removed.
    public func legacyPinMigrationOps(_ refs: [LayoutItemRef]) -> [SidebarLayoutOp] {
        []
    }
}

extension SidebarLayoutDocument {
    /// The first top-region item showing `ref` in `room` (the tile or top
    /// row the selection marks while the window shows that workspace).
    public func topItem(for ref: LayoutItemRef, room: String?) -> LayoutItem? {
        nil
    }
}
