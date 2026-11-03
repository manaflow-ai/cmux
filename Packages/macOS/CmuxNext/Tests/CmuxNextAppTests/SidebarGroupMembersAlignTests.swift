import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-21, on a group's rows sitting ~12 pt right of the rows above them, with the selected
/// row's capsule inside that indent: "THE STUPID INDENT, IS THAT CHROME???? WHY IS THERE INDENT ON
/// THIS INDENT FOR WHAT". A top-level group's members now keep an ungrouped row's left edge: the same
/// row frame (so the same hover and selection capsule) and the same leading content x. The group shows
/// by its header and its members' line, which runs in the list's inset beside the rows, never over
/// them or pushing them in (his 2026-10-03 rule: "a thin colored vertical line ties members together,
/// with no extra indent").
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarGroupMembersAlignTests {
    static let group = GroupID("g-coordinator")
    static let looseID = WorkspaceID("ws-loose")
    static let leadID = WorkspaceID("ws-lead")
    static let otherID = WorkspaceID("ws-95")

    static func sidebar(selected: WorkspaceID) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let coordinator = SidebarGroup(id: group, name: "Coordinator", color: .blue, workspaces: [
            SidebarWorkspace(id: leadID, title: "COORDINATOR (claude-sr2) - working view"),
            SidebarWorkspace(id: otherID, title: "workspace-95"),
        ])
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: looseID, title: "scratch")), .group(coordinator)]),
        ], activeWorkspaceID: selected)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        window.contentView = root
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return (sidebar, window)
    }

    static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView, "no row for \(id.rawValue)")
    }

    /// The selected member (Leo's screenshot) and an unselected one, against the ungrouped row.
    @Test(arguments: [true, false])
    func groupMembersKeepTheUngroupedRowsLeftEdgeAndWidth(memberSelected: Bool) throws {
        let (sidebar, window) = Self.sidebar(selected: memberSelected ? Self.leadID : Self.looseID)
        defer { window.close() }
        let list = sidebar.list
        let loose = try Self.row(sidebar, Self.looseID)
        for id in [Self.leadID, Self.otherID] {
            let member = try Self.row(sidebar, id)
            let row = try #require(list.displayed.row(for: .workspace(id)))
            #expect(row.group == Self.group, "\(id.rawValue) is not in the group")
            #expect(member.frame.minX == loose.frame.minX, "\(id.rawValue): row starts at \(member.frame.minX), ungrouped at \(loose.frame.minX)")
            #expect(member.frame.width == loose.frame.width, "\(id.rawValue): row is \(member.frame.width) wide, ungrouped \(loose.frame.width)")
            #expect(list.frame(for: row).minX == list.inset, "\(id.rawValue): the list places it \(list.frame(for: row).minX - list.inset) pt in")
            let memberText = list.convert(member.title.frame, from: member).minX
            let looseText = list.convert(loose.title.frame, from: loose).minX
            #expect(memberText == looseText, "\(id.rawValue): title starts at \(memberText), ungrouped at \(looseText)")
        }
        // The header bar starts at its members' rail, just left of the rows (Lawrence 2026-10-23), its name on their text
        // column, and keeps `groupEdgePadding` from the list's edge (Lawrence 2026-10-25, b5400e7e342f4: "groups headers and
        // rails need more left padding"), as the rail does (`SidebarGroupLineLayoutTests`).
        let header = try #require(list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
        #expect(header.frame.minX == max(loose.frame.minX - SidebarStyle.groupRailReach, SidebarStyle.groupEdgePadding),
                "header starts at \(header.frame.minX), rows at \(loose.frame.minX)")
    }

    /// The members' line stays (the group's mark) but sits in the inset left of the rows: it never pushes them in
    /// and no row's fill covers it.
    @Test func theMembersLineRunsBesideTheRowsNotUnderAnIndent() throws {
        let (sidebar, window) = Self.sidebar(selected: Self.leadID)
        defer { window.close() }
        let list = sidebar.list
        let lines = SidebarGroupLine.lines(list.displayed.rows, colors: list.groups) { list.frame(for: $0) }
        let line = try #require(lines.first { $0.group == Self.group }, "the open group has no members' line")
        #expect(line.frame.minX >= 0, "the line \(line.frame) runs off the list")
        for id in [Self.leadID, Self.otherID] {
            let member = try Self.row(sidebar, id)
            #expect(line.frame.maxX <= member.frame.minX, "the line \(line.frame) runs under \(id.rawValue)'s row \(member.frame)")
        }
        if let shown = list.groupLineViews.shown[Self.group] {
            #expect(shown.frame.minX == line.frame.minX, "the drawn line \(shown.frame) is not where its rows put it \(line.frame)")
        }
    }

    /// Lifting the group keeps the line beside its rows on the card: the card reaches over the line, so neither
    /// the line nor the rows move sideways and no member's fill covers the line.
    @Test func aLiftedGroupKeepsItsLineBesideItsRows() throws {
        let (sidebar, window) = Self.sidebar(selected: Self.leadID)
        defer { window.close() }
        let list = sidebar.list
        let header = try #require(list.displayed.row(for: .group(Self.group)))
        let line = try #require(SidebarGroupLine.lines(list.displayed.rows, colors: list.groups) { list.frame(for: $0) }.first)
        list.press = SidebarPress(key: header.key, point: NSPoint(x: 80, y: header.y + header.height / 2))
        list.beginDrag(try #require(list.press))
        defer {
            list.cancelDrag()
            if let landing = list.landing { list.finishLand(landing, then: nil) }
        }
        let lift = try #require(list.subviews.first { $0 is DragLiftView })
        #expect(lift.frame.minX == line.frame.minX, "the card starts at \(lift.frame.minX), the line at \(line.frame.minX)")
        let block = try #require(Self.descendant(of: lift) { $0 is SidebarLiftBlockView })
        let members = block.subviews.compactMap { $0 as? WorkspaceRowView }
        let lines = block.subviews.filter { !($0 is SidebarRowView) }
        #expect(members.count == 2 && lines.count == 1, "card holds \(members.count) members and \(lines.count) lines")
        for drawn in lines {
            #expect(drawn.frame.minX >= 0, "the card clips the line at \(drawn.frame)")
            for member in members {
                #expect(drawn.frame.maxX <= member.frame.minX, "on the card the line \(drawn.frame) runs under \(member.frame)")
            }
        }
    }

    /// Letting go (a cancel lands the card back in its slot) puts the card where it lifted from, line included:
    /// no sideways jump when the real rows and line take its place.
    @Test func aCancelledGroupDragLandsWhereItLifted() throws {
        let (sidebar, window) = Self.sidebar(selected: Self.leadID)
        defer { window.close() }
        let list = sidebar.list
        let header = try #require(list.displayed.row(for: .group(Self.group)))
        list.press = SidebarPress(key: header.key, point: NSPoint(x: 80, y: header.y + header.height / 2))
        list.beginDrag(try #require(list.press))
        let lift = try #require(list.subviews.first { $0 is DragLiftView })
        let lifted = lift.frame
        list.cancelDrag()
        #expect(abs(lift.frame.minX - lifted.minX) < 0.5 && abs(lift.frame.width - lifted.width) < 0.5,
                "the card lands at \(lift.frame), it lifted at \(lifted)")
        if let landing = list.landing { list.finishLand(landing, then: nil) }
    }

    static func descendant(of view: NSView, where match: (NSView) -> Bool) -> NSView? {
        for child in view.subviews {
            if match(child) { return child }
            if let found = descendant(of: child, where: match) { return found }
        }
        return nil
    }

    /// Nesting still reads: a nested group's rows step in one gutter per level below the top, and a top-level
    /// group's rows (level 1) not at all.
    @Test func onlyNestedLevelsStepIn() {
        #expect(SidebarStyle.groupOffset(depth: 0) == 0)
        #expect(SidebarStyle.groupOffset(depth: 1) == 0)
        #expect(SidebarStyle.groupOffset(depth: 2) == SidebarStyle.groupGutter)
        #expect(SidebarStyle.groupOffset(depth: 3) == SidebarStyle.groupGutter * 2)
    }
}
