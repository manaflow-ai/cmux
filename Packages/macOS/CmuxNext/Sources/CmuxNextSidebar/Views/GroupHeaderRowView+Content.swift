import AppKit
import CmuxNextDesign

extension GroupHeaderRowView {
    /// What the header shows of its group, its row and the settings: a change to nothing here (a member's progress
    /// tick, a member's title) configures nothing. It held the whole group, members included, so each status tick of a
    /// member configured its group's header in full (the chevron's raster, the member count's localized words,
    /// VoiceOver's label): in the fleet's 400-workspace sidebar with 15 agents ticking, 441 samples across the
    /// workspace switch matrix and 127 while ticking, for headers that showed nothing new.
    struct Content: Hashable {
        var id: GroupID
        var name: String
        var color: GroupColor
        var custom: String?
        var isPinned: Bool
        var isArchived: Bool
        var icon: WorkspaceIcon?
        var machine: SidebarMachine?
        var look: SidebarHostGroupLook
        var childCount: Int
        var collapsed: Bool
        var fontSize: CGFloat
        var details: GroupHeaderDetails
        /// The status mark the header shows.
        var status: StatusIndicatorState
        /// The unread total its badge shows; 0 shows none.
        var unread: Int

        /// What a header configured for `group` and `row` shows; `rollUp` as ``configure(_:row:details:status:animated:)``.
        init(_ group: SidebarGroup, row: SidebarRow, details: GroupHeaderDetails, rollUp: StatusIndicatorState?) {
            let folded = row.isCollapsed
            id = group.id
            name = group.name
            color = group.color
            custom = group.custom
            isPinned = group.isPinned
            isArchived = group.isArchived
            icon = group.icon
            machine = group.machine
            look = group.hostLook
            childCount = row.childCount
            collapsed = folded
            fontSize = SidebarStyle.headerFont.pointSize
            self.details = details
            // Lawrence 2026-10-20: "All we care about is the loading"; msg 11983: and blue, orange and red.
            status = folded && details.otherStates ? group.aggregateActivity : rollUp ?? group.statusRollUp(collapsed: folded)
            unread = details.unreadCount && folded ? group.unreadTotal : 0
        }
    }
}
