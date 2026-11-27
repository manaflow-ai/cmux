import CoreGraphics

// One drop look for every section of the sidebar document (sidebar-v2):
// every drag is hit-tested by `SidebarDragGeometry` against its one
// `drag_begin` table over the list rows and the blocks' items, and its drop
// opens a gap where it goes (`gap`: list rows or a block's items make way)
// or fills the header of the group it goes into (`into`); a refused place
// opens nothing and turns the lift refused (`refused`).

extension SidebarDocDrag {
    /// The slots of a block's items (`layout`, the region's base layout) at
    /// `y` in the list: a tile or chip on its line, a row, the section
    /// header (the drop goes first). Client-only items and app sections take none.
    func blockSlots(_ layout: SidebarRegionLayout, at y: CGFloat) -> [SidebarDragGeometry.Slot] {
        var slots: [SidebarDragGeometry.Slot] = []
        for row in layout.rows {
            let frame = row.frame.offsetBy(dx: 0, dy: y)
            switch row.kind {
            case let .header(section):
                slots.append(.init(key: section.rawValue, item: nil, section: section.rawValue, frame: frame, kind: .section))
            case let .item(id, section) where !id.isTransient:
                slots.append(.init(key: id.rawValue, item: id.rawValue, section: section.rawValue, frame: frame, kind: .row))
            case let .tile(id, section) where !id.isTransient:
                slots.append(.init(key: id.rawValue, item: id.rawValue, section: section.rawValue, frame: frame, kind: .tile))
            case let .chip(id, section) where !id.isTransient:
                slots.append(.init(key: id.rawValue, item: id.rawValue, section: section.rawValue, frame: frame, kind: .tile))
            default:
                continue
            }
        }
        return slots
    }
}

extension SidebarDropProbe {
    /// The probe of a document hit: the slot, the zone and the drop look
    /// (`gap`, `into` a group header, or `refused`).
    init(_ hit: SidebarDragGeometry.Hit?, displayY: CGFloat, baseY: CGFloat?) {
        let fraction = hit.map { hit in hit.slot.frame.height > 0 ? (((baseY ?? displayY) - hit.slot.frame.minY) / hit.slot.frame.height) : 0 }
        let look: String? = hit.map { hit in hit.target == nil ? "refused" : hit.zone == .into && hit.slot.kind == .group ? "into" : "gap" }
        self.init(edge: "pointer", displayY: displayY, baseY: baseY, row: hit?.slot.key, fraction: fraction,
                  target: hit?.target.map { String(describing: $0) }, indicator: look, refusal: hit?.refusal)
    }
}
