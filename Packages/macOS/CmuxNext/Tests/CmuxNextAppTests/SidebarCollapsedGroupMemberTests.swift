import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-21 (screenshot: a collapsed group "cmux-next app" with its selected member
/// "Right sidebar cleanup" drawn under the header, no line beside it): "should still show left rail,
/// and if we choose another workspace, it should completely disappear". A collapsed group that draws
/// its active member draws the members' line beside it, as an open group does; once another
/// workspace is selected, that member folds away with its line, and no fill stays on it.
@MainActor @Suite(.serialized) struct SidebarCollapsedGroupMemberTests {
    static let group = GroupID("g-cmux-next-app")
    static let memberID = WorkspaceID("ws-right-sidebar-cleanup")
    static let otherMemberID = WorkspaceID("ws-other-member")
    static let looseID = WorkspaceID("ws-131")

    /// A sidebar with one collapsed group (pinned or not, in the pinned area or the machine's list)
    /// whose member `memberID` is active, and one ungrouped workspace below it.
    static func sidebar(pinned: Bool) -> (SidebarView, SidebarModel, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let group = SidebarGroup(id: group, name: "cmux-next app", color: .grey, isCollapsed: true, isPinned: pinned, workspaces: [
            SidebarWorkspace(id: memberID, title: "Right sidebar cleanup"),
            SidebarWorkspace(id: otherMemberID, title: "Monaco bar cursor default"),
        ])
        let loose = SidebarWorkspace(id: looseID, title: "workspace-131")
        let sections: [SidebarSection] = pinned
            ? [SidebarSection(kind: .pinned, nodes: [.group(group)]), SidebarSection(kind: .machine(machine), nodes: [.workspace(loose)])]
            : [SidebarSection(kind: .machine(machine), nodes: [.group(group), .workspace(loose)])]
        let model = SidebarModel(sections: sections, activeWorkspaceID: memberID)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        window.contentView = root
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.list.pointerIsOverList = { _ in false }
        sidebar.list.reload(animated: false, fromModel: true)
        return (sidebar, model, window)
    }

    static func lines(_ list: SidebarListView) -> [SidebarGroupLine] {
        SidebarGroupLine.lines(list.displayed.rows, colors: list.groups) { list.frame(for: $0) }
    }

    /// The selected member of a collapsed group has the members' line beside it.
    @Test(arguments: [false, true])
    func aCollapsedGroupsActiveMemberHasTheMembersLine(pinned: Bool) throws {
        let (sidebar, _, window) = Self.sidebar(pinned: pinned)
        defer { window.close() }
        let list = sidebar.list
        let member = try #require(list.displayed.row(for: .workspace(Self.memberID)), "the collapsed group does not draw its active member")
        #expect(list.selectedRowKey == .workspace(Self.memberID))
        let line = try #require(Self.lines(list).first { $0.group == Self.group }, "the active member of a collapsed group has no members' line")
        let rowFrame = list.frame(for: member)
        #expect(line.frame.minY < rowFrame.maxY && line.frame.maxY > rowFrame.minY, "the line \(line.frame) is not beside the row \(rowFrame)")
        #expect(line.frame.maxX <= rowFrame.minX + 0.5, "the line \(line.frame) runs under the row \(rowFrame)")
        // The drawn line view, not just the computed one.
        let views = GroupPaletteDefaultTests.views(GroupLineView.self, in: sidebar)
        #expect(views.contains { !$0.isHidden && $0.alphaValue > 0 }, "no members' line view is drawn")
    }

    /// Selecting another workspace (a key, the palette, a click with the pointer then leaving) folds the old member
    /// away: no row, no line, no fill left on the group.
    @Test(arguments: [false, true])
    func selectingAnotherWorkspaceFoldsTheOldMemberAway(pinned: Bool) throws {
        let (sidebar, model, window) = Self.sidebar(pinned: pinned)
        defer { window.close() }
        let list = sidebar.list
        model.selectedItem = .workspace(Self.looseID)
        sidebar.renderNow()
        #expect(list.displayed.row(for: .workspace(Self.memberID)) == nil, "the old member still shows under its collapsed group")
        #expect(list.rowViews[.workspace(Self.memberID)] == nil || list.rowViews[.workspace(Self.memberID)]?.isHidden == true
                    || list.rowViews[.workspace(Self.memberID)]?.alphaValue == 0, "the old member's row view still shows")
        #expect(Self.lines(list).first { $0.group == Self.group } == nil, "the collapsed group still draws a members' line")
        #expect(list.selectedRowKey == .workspace(Self.looseID))
        #expect(list.rowViews.values.filter(\.isSelected).map(\.key) == [.workspace(Self.looseID)], "a stale row still paints the selection")
    }

    /// A click while the pointer stays over the rows moves no row (Leo, #22960); the member folds away when the
    /// pointer leaves the list.
    @Test func aClickedAwayMemberFoldsWhenThePointerLeaves() throws {
        let (sidebar, model, window) = Self.sidebar(pinned: false)
        defer { window.close() }
        let list = sidebar.list
        var pointerOver = true
        list.pointerIsOverList = { _ in pointerOver }
        model.selectedItem = .workspace(Self.looseID)
        sidebar.renderNow()
        #expect(list.displayed.row(for: .workspace(Self.memberID)) != nil, "a click under the pointer moved rows")
        #expect(list.rowViews[.workspace(Self.memberID)]?.isSelected == false, "the old member still paints the selection")

        pointerOver = false
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                       trackingNumber: 0, userData: nil))
        list.mouseExited(with: exit)
        #expect(list.displayed.row(for: .workspace(Self.memberID)) == nil, "the old member did not fold away when the pointer left")
        #expect(Self.lines(list).first { $0.group == Self.group } == nil, "the line stayed after the member folded")
    }
}
