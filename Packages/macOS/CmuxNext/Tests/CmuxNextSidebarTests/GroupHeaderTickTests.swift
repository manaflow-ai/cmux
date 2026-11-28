import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A member's status tick that changes nothing its group's header shows configures nothing in that header (CMUX NEXT
/// Stable perf gate). The header compared the whole group, members included, so every progress tick of a working
/// member configured its group's header in full: in the fleet's 400-workspace sidebar with 15 agents ticking, 441
/// samples across the workspace switch matrix and 127 while ticking. A change the header shows still reaches it,
/// as it reaches a header made for the new group.
@MainActor @Suite struct GroupHeaderTickTests {
    static let groupID = GroupID("tick-g")

    static func member(_ n: Int, _ activity: StatusIndicatorState = .idle, unread: UnreadState = .none,
                       title: String? = nil) -> SidebarWorkspace {
        var workspace = SidebarWorkspace(id: WorkspaceID("tick-\(n)"), title: title ?? "tick-\(n)")
        workspace.activity = activity
        workspace.unread = unread
        return workspace
    }

    static var group: SidebarGroup {
        SidebarGroup(id: groupID, name: "Agents", color: .green, workspaces: (0..<3).map { member($0) })
    }

    /// A group already showing things: a member waits on the person, another has unread output, pinned, with an icon.
    static var busyGroup: SidebarGroup {
        var group = group
        group.workspaces[0].activity = .waiting(kind: nil)
        group.workspaces[2].unread = .count(2)
        group.isPinned = true
        group.icon = GroupHeaderRowView.folderIcon
        return group
    }

    static var everything: GroupHeaderDetails {
        var details = GroupHeaderDetails()
        details.memberCount = true
        details.unreadCount = true
        details.otherStates = true
        return details
    }

    /// A sidebar listing the group, then loose rows; its header view and row.
    static func header() throws -> (GroupHeaderRowView, SidebarRow, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let nodes = [SidebarNode.group(group)] + (3..<10).map { SidebarNode.workspace(member($0)) }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        let header = try #require(sidebar.list.rowViews[.group(groupID)] as? GroupHeaderRowView, "no group header shown")
        let row = try #require(sidebar.list.displayed.groupRow(groupID))
        return (header, row, window)
    }

    /// Member 1 ticks its progress (and member 2 is renamed) while member 0, working at a fixed progress, is the one a
    /// folded header shows (both report progress; the first id wins), so the header shows nothing new.
    @Test(arguments: [false, true], [false, true])
    func aMemberProgressTickConfiguresNothingInItsGroupHeader(_ folded: Bool, _ allDetails: Bool) throws {
        let (header, shownRow, window) = try Self.header()
        defer { window.close() }
        var row = shownRow
        row.isCollapsed = folded
        let details = allDetails ? Self.everything : GroupHeaderDetails()
        var group = Self.group
        group.workspaces[0].activity = .working(progress: 0.5)
        group.workspaces[1].activity = .working(progress: 0.1)
        header.configure(group, row: row, details: details, animated: false)
        let configured = header.configuredContent
        let drawn = header.debugDrawn
        for progress in [0.2, 0.3, 0.4] {
            group.workspaces[1].activity = .working(progress: progress)
            group.workspaces[2].title = "renamed \(progress)"
            header.configure(group, row: row, details: details, animated: false)
            #expect(header.configuredContent == configured,
                    "a member's progress tick (\(progress)) configured its \(folded ? "folded" : "open") group's header again")
            #expect(header.debugDrawn == drawn)
        }
        // The member the folded header shows still reaches it.
        group.workspaces[0].activity = .working(progress: 0.6)
        header.configure(group, row: row, details: details, animated: false)
        #expect((header.configuredContent != configured) == folded,
                "the shown member's tick \(folded ? "did not reach the folded" : "reached the open") header")
    }

    /// What the header shows: VoiceOver's label and hint, the member count, the badge, the status mark, the archived
    /// look, the disclosure, and what it draws (tint, pin, icon, machine, the status it keeps).
    static func shown(_ view: GroupHeaderRowView) -> String {
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        view.layoutSubtreeIfNeeded()
        return "\(view.accessibilityLabel() ?? "-") | \(view.accessibilityHelp() ?? "-") | count \(view.countText ?? "-")"
            + " | badge \(view.debugBadge) | activity \(view.debugActivityVisible) | archived \(view.debugArchived)"
            + " | disclosure \(view.debugDisclosure?.icon ?? "-") | expanded \(view.isAccessibilityExpanded())"
            + " | \(view.debugDrawn)"
    }

    /// Each change a header shows, from `group` and its row.
    static func change(_ name: String, _ group: inout SidebarGroup, _ row: inout SidebarRow) {
        switch name {
        case "renamed": group.name = "Agents 2"
        case "color": group.color = .blue
        case "custom color": group.custom = "#3366CC"
        case "no color": group.custom = GroupTint.noneWire
        case "pinned": group.isPinned.toggle()
        case "archived": group.isArchived = true
        case "icon": group.icon = group.icon == nil ? GroupHeaderRowView.folderIcon : nil
        case "unread": group.workspaces[1].unread = .count(3)
        case "dot": group.workspaces[1].unread = .dot
        case "waiting": group.workspaces[1].activity = .waiting(kind: nil)
        case "error": group.workspaces[1].activity = .error
        case "success": group.workspaces[1].activity = .success
        case "working": group.workspaces[1].activity = .working(progress: 0.5)
        case "member left":
            group.workspaces.removeLast()
            row.childCount -= 1
        case "member renamed": group.workspaces[1].title = "other"
        case "machine": group.machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        case "look": group.hostLook = .markAndWords
        default: Issue.record("no change named \(name)")
        }
    }

    @Test(arguments: ["renamed", "color", "custom color", "no color", "pinned", "archived", "icon", "unread", "dot",
                      "waiting", "error", "success", "working", "member left", "member renamed", "machine", "look"])
    func aChangedGroupShowsWhatAFreshHeaderShows(_ name: String) throws {
        let (header, shownRow, window) = try Self.header()
        defer { window.close() }
        for start in [Self.group, Self.busyGroup] {
            for details in [GroupHeaderDetails(), Self.everything] {
                for folded in [false, true] {
                    var row = shownRow
                    row.isCollapsed = folded
                    var after = start
                    var afterRow = row
                    Self.change(name, &after, &afterRow)
                    header.configure(start, row: row, details: details, animated: false)
                    header.configure(after, row: afterRow, details: details, animated: false)
                    let fresh = GroupHeaderRowView(key: .group(Self.groupID))
                    fresh.configure(after, row: afterRow, details: details, animated: false)
                    #expect(Self.shown(header) == Self.shown(fresh),
                            "\(name) from \(start == Self.group ? "plain" : "busy"), \(folded ? "folded" : "open"), details \(details == Self.everything ? "all" : "default")")
                }
            }
        }
    }
}
