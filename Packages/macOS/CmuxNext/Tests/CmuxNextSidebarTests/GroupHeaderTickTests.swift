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

    /// A sidebar listing the group, then loose rows; its header view and row.
    static func header() throws -> (GroupHeaderRowView, SidebarRow, SidebarModel, NSWindow) {
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
        return (header, row, model, window)
    }

    @Test(arguments: [false, true])
    func aMemberProgressTickConfiguresNothingInItsGroupHeader(_ folded: Bool) throws {
        let (header, shownRow, model, window) = try Self.header()
        defer { window.close() }
        var row = shownRow
        row.isCollapsed = folded
        var group = Self.group
        group.workspaces[0].activity = .working(progress: nil)
        group.workspaces[1].activity = .working(progress: 0.1)
        header.configure(group, row: row, details: model.groupHeaderDetails, animated: false)
        let configured = header.configuredContent
        for progress in [0.2, 0.3, 0.4] {
            group.workspaces[1].activity = .working(progress: progress)
            group.workspaces[2].title = "renamed \(progress)"
            header.configure(group, row: row, details: model.groupHeaderDetails, animated: false)
            #expect(header.configuredContent == configured,
                    "a member's progress tick (\(progress)) configured its \(folded ? "folded" : "open") group's header again")
        }
    }

    /// What the header shows: VoiceOver's label and hint, the member count, the badge, the status mark, the archived
    /// look, the disclosure.
    static func shown(_ view: GroupHeaderRowView) -> String {
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        view.layoutSubtreeIfNeeded()
        return "\(view.accessibilityLabel() ?? "-") | \(view.accessibilityHelp() ?? "-") | count \(view.countText ?? "-")"
            + " | badge \(view.debugBadge) | activity \(view.debugActivityVisible) | archived \(view.debugArchived)"
            + " | disclosure \(view.debugDisclosure?.icon ?? "-") | expanded \(view.isAccessibilityExpanded())"
    }

    /// Each change a header shows, from a plain group.
    static func changed(_ name: String) -> SidebarGroup {
        var group = group
        switch name {
        case "renamed": group.name = "Agents 2"
        case "pinned": group.isPinned = true
        case "archived": group.isArchived = true
        case "icon": group.icon = GroupHeaderRowView.folderIcon
        case "unread": group.workspaces[1].unread = .count(3)
        case "dot": group.workspaces[1].unread = .dot
        case "waiting": group.workspaces[1].activity = .waiting(kind: nil)
        case "error": group.workspaces[1].activity = .error
        case "success": group.workspaces[1].activity = .success
        case "working": group.workspaces[1].activity = .working(progress: 0.5)
        case "member renamed": group.workspaces[1].title = "other"
        case "machine": group.machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        default: Issue.record("no change named \(name)")
        }
        return group
    }

    @Test(arguments: ["renamed", "pinned", "archived", "icon", "unread", "dot", "waiting", "error", "success", "working",
                      "member renamed", "machine"])
    func aChangedGroupShowsWhatAFreshHeaderShows(_ name: String) throws {
        let (header, shownRow, _, window) = try Self.header()
        defer { window.close() }
        let after = Self.changed(name)
        var everything = GroupHeaderDetails()
        everything.memberCount = true
        everything.unreadCount = true
        everything.otherStates = true
        for details in [GroupHeaderDetails(), everything] {
            for folded in [false, true] {
                var row = shownRow
                row.isCollapsed = folded
                header.configure(Self.group, row: row, details: details, animated: false)
                header.configure(after, row: row, details: details, animated: false)
                let fresh = GroupHeaderRowView(key: .group(Self.groupID))
                fresh.configure(after, row: row, details: details, animated: false)
                #expect(Self.shown(header) == Self.shown(fresh),
                        "\(name), \(folded ? "folded" : "open"), details \(details == everything ? "all" : "default")")
            }
        }
    }
}
