import CoreGraphics

extension SidebarRow {
    /// How far right of the list's inset this row starts (`SidebarStyle.groupOffset(depth:)`).
    ///
    /// The one source of a row's leading offset (`SidebarListView.frame(for:)`; a group's line is placed
    /// from its members' frames, `SidebarStyle.groupLineX`). It reads only `depth` and `group`, which the
    /// layout takes from the groups the list holds (`SidebarSection.resolvingGroupDepths`), so every
    /// top-level group's header, line and members line up with each other and with ungrouped rows, and
    /// only a nested group's rows step in (remote-groups-DESIGN.md slice 2).
    var groupGutter: CGFloat {
        switch key {
        case .workspace, .tab, .item, .doneFold, .showMore, .emptyGroup: group == nil ? 0 : SidebarStyle.groupOffset(depth: depth)
        case .group: SidebarStyle.groupOffset(depth: depth)
        default: 0
        }
    }
}
