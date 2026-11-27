import AppKit

/// App-section headers use the region's existing lifted drag. Only the
/// target band's geometry is handled here; the drop forwards a normal
/// section move to the shared document.
@MainActor enum SidebarAppSectionDrops {
    static func target(_ sidebar: SidebarView, section id: LayoutSectionID, at windowPoint: NSPoint?) -> SidebarLayoutOp? {
        guard let windowPoint, let source = sidebar.model.layout.section(id), source.content == .app,
              source.region == .top || source.region == .bottom else {
            sidebar.hideDropOutline()
            return nil
        }
        let destination: SidebarRegion = source.region == .top ? .bottom : .top
        let point = sidebar.convert(windowPoint, from: nil)
        let regions = destination == .bottom ? [sidebar.belowRegion] : [sidebar.aboveRegion] + sidebar.list.blockRegions
        let visible = destination == .bottom ? sidebar.belowFade.frame : sidebar.aboveFade.frame.union(sidebar.edgeFade.frame)
        var frames: [LayoutSectionID: CGRect] = [:]
        for region in regions {
            for section in region.displayedSections where section.content == .app && section.region == destination {
                guard let local = SidebarRegionReorder.frame(of: section.id, in: region.layoutResult) else { continue }
                let frame = sidebar.convert(local, from: region).intersection(visible)
                if !frame.isNull, frame.height > 0 { frames[section.id] = frame }
            }
        }
        let edge = destination == .bottom ? sidebar.belowFade.frame.minY : sidebar.aboveFade.frame.minY
        // An empty app band still takes a header drop at its edge, without
        // reserving any space while no drag is running.
        let empty = CGRect(x: 0, y: destination == .bottom ? edge - SidebarDensityTokens.rowHeight : edge,
                           width: sidebar.bounds.width, height: SidebarDensityTokens.rowHeight)
        let band = frames.values.reduce(destination == .bottom ? sidebar.belowFade.frame : sidebar.aboveFade.frame) { $0.union($1) }
        let hit = band.height > 0 ? band : empty
        guard hit.contains(point) else {
            sidebar.hideDropOutline()
            return nil
        }
        let sections = sidebar.model.layout.appSections(in: destination, room: sidebar.model.activeProfileID?.rawValue)
            .presenting(hidingItems: [], apps: sidebar.model.suppressedApps)
        let before = sections.first { frames[$0.id].map { point.y < $0.midY } == true }?.id
        guard let op = SidebarRegionReorder.appSectionMove(id, to: destination, before: before,
                                                         shown: sections, document: sidebar.model.layout) else { return nil }
        sidebar.showDropOutline(sidebar.convert(hit, to: nil), refused: false)
        return op
    }
}
