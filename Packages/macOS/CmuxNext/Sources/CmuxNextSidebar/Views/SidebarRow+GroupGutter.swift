import CoreGraphics

extension SidebarRow {
    /// The level this row draws at (`SidebarIndent`): ungrouped rows 0; a group's header and its members share
    /// one level, the group's depth + 1, so a header always sits at its own members' x and a subgroup (header and
    /// members) steps in one level from its parent. Nesting can never read as a sibling drawn a little to the right.
    ///
    /// It reads only `depth` and `group`, which the layout takes from the groups the list holds
    /// (`SidebarSection.resolvingGroupDepths`): a stale stored depth or a missing parent draws at the top level.
    var indentLevel: Int {
        switch key {
        case .workspace, .item, .doneFold, .showMore, .emptyGroup: group == nil ? 0 : max(1, depth)
        case .group: depth + 1
        default: 0
        }
    }

    /// How far right of the list's inset this row starts, with no width cap (`SidebarIndent.offset`; its level cap stays).
    ///
    /// The same rule `SidebarListView.frame(for:)` draws with (`indentOffset(for:)`, which also caps deep levels
    /// in a narrow list): every top-level group's header, line and members line up with each other and with
    /// ungrouped rows, and each nested level steps in one gutter (remote-groups-DESIGN.md slice 2).
    var groupGutter: CGFloat {
        SidebarIndent(step: SidebarStyle.groupGutter).offset(level: indentLevel, width: .greatestFiniteMagnitude)
    }
}
