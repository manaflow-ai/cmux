import AppKit

// Drop-to-pin (PINNED-ITEMS-END-TO-END P2): a workspace row dragged from the
// list onto the tiles or the top rows joins that section at the drop point;
// a workspace tile or top row dragged onto the list leaves the band. Both
// go through the one layout path (the App's PinCommands, undoable) and show
// the shared drop outline around the place that takes the drop. (A helper
// type: SidebarView is at its god-type limit.)
@MainActor enum SidebarPinDrops {
    static func install(_ sidebar: SidebarView) {
        sidebar.aboveRegion.dropToListProbe = { [weak sidebar] windowPoint in sidebar.map { isOverList($0, windowPoint) } ?? false }
        sidebar.aboveRegion.onDropToList = { [weak sidebar] id in sidebar?.model.send(.layout(.itemRemove(id))) }
    }

    /// The top section under `windowPoint` that would take a workspace row,
    /// outlined; nil (and no outline) elsewhere or when the drag ended.
    static func pinDrop(_ sidebar: SidebarView, at windowPoint: NSPoint?) -> SidebarRegionDrop? {
        let scroll = sidebar.aboveScroll, region = sidebar.aboveRegion
        guard let windowPoint, !scroll.isHidden, scroll.bounds.contains(scroll.convert(windowPoint, from: nil)),
              let metrics = region.content?.metrics,
              let drop = SidebarRegionDrop.target(at: region.convert(windowPoint, from: nil), layout: region.layoutResult,
                                                  sections: sidebar.model.layout.sections, gap: metrics.sectionGap) else {
            sidebar.hideDropOutline()
            return nil
        }
        sidebar.showDropOutline(region.convert(drop.frame, to: nil), refused: false)
        return drop
    }

    /// Where a row dropped as `drop` lands (window coordinates): the slot of
    /// the item it goes before, or past the section's last item.
    static func slot(_ sidebar: SidebarView, for drop: SidebarRegionDrop) -> NSRect? {
        let region = sidebar.aboveRegion
        let rows = region.layoutResult.rows.filter { SidebarRegionReorder.item(of: $0)?.1 == drop.section }
        let frame: CGRect
        if drop.index < rows.count {
            frame = rows[drop.index].frame
        } else if let last = rows.last {
            switch last.kind {
            case .tile, .chip:
                let gap = rows.count > 1 ? max(0, rows[1].frame.minX - rows[0].frame.maxX) : 0
                let beside = last.frame.offsetBy(dx: last.frame.width + gap, dy: 0)
                frame = beside.maxX <= region.bounds.maxX ? beside : CGRect(origin: CGPoint(x: rows[0].frame.minX, y: last.frame.maxY + gap),
                                                                           size: last.frame.size)
            default:
                frame = last.frame.offsetBy(dx: 0, dy: last.frame.height)
            }
        } else {
            frame = drop.frame
        }
        return region.convert(frame, to: nil)
    }

    /// Whether `windowPoint` is over the workspace list (outlined); false
    /// (and no outline) elsewhere or when the drag ended.
    static func isOverList(_ sidebar: SidebarView, _ windowPoint: NSPoint?) -> Bool {
        guard let windowPoint, let scroll = sidebar.list.enclosingScrollView,
              scroll.bounds.contains(scroll.convert(windowPoint, from: nil)) else {
            sidebar.hideDropOutline()
            return false
        }
        sidebar.showDropOutline(scroll.convert(scroll.bounds, to: nil), refused: false)
        return true
    }
}
