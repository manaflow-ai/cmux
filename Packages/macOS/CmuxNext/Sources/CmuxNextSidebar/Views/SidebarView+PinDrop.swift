import AppKit

// Drop-to-pin (PINNED-ITEMS-END-TO-END P2): a workspace row dragged from the
// list onto the tiles or the top rows joins that section at the drop point;
// a workspace tile or top row dragged onto the list leaves the band. Both
// go through the one layout path (the App's PinCommands, undoable) and show
// the shared drop outline around the place that takes the drop.
extension SidebarView {
    func installPinDrops() {
        // red: the band does not take tiles out yet
    }

    /// The top section under `windowPoint` that would take a workspace row,
    /// outlined; nil (and no outline) elsewhere or when the drag ended.
    func pinDrop(at windowPoint: NSPoint?) -> SidebarRegionDrop? {
        guard let windowPoint, !aboveScroll.isHidden, aboveScroll.bounds.contains(aboveScroll.convert(windowPoint, from: nil)),
              let metrics = aboveRegion.content?.metrics,
              let drop = SidebarRegionDrop.target(at: aboveRegion.convert(windowPoint, from: nil), layout: aboveRegion.layoutResult,
                                                  sections: model.layout.sections, gap: metrics.sectionGap) else {
            hideDropOutline()
            return nil
        }
        showDropOutline(aboveRegion.convert(drop.frame, to: nil), refused: false)
        return drop
    }

    /// Whether `windowPoint` is over the workspace list (outlined); false
    /// (and no outline) elsewhere or when the drag ended.
    func isOverList(_ windowPoint: NSPoint?) -> Bool {
        guard let windowPoint, let scroll = list.enclosingScrollView, scroll.bounds.contains(scroll.convert(windowPoint, from: nil)) else {
            hideDropOutline()
            return false
        }
        showDropOutline(scroll.convert(scroll.bounds, to: nil), refused: false)
        return true
    }
}
