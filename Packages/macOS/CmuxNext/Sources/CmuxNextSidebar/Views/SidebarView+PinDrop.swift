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
