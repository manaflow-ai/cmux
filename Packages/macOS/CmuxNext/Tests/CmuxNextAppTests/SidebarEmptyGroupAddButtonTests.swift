import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// User msg 17912 ("empty workspace needs plus button", a shot of an open, empty "Sleep alarm" group): the
/// empty group's row read only "No workspaces · drag one here", and its header hid the + an empty group needs
/// most. The row shows a + at rest, and the header offers its + on hover as a full group's does; both run
/// New Workspace in Group, the one action path the group editor, menu, palette and CLI share.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarEmptyGroupAddButtonTests {
    private static let group = GroupID("grp-empty")

    /// A sidebar in a window with one open, empty group; `ran` collects the group actions it runs.
    private static func sidebar() -> (SidebarView, NSWindow, Ran) {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let empty = SidebarGroup(id: group, name: "Sleep alarm", color: .purple, workspaces: [])
        let loose = SidebarWorkspace(id: WorkspaceID("loose"), title: "loose")
        let sidebar = SidebarView(model: SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.group(empty), .workspace(loose)])]),
                                  design: DesignSettings())
        let ran = Ran()
        sidebar.list.onGroupEditorItem = { id, item in ran.items.append("\(id.rawValue) \(item)") }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 280, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 500)
        window.contentView?.addSubview(sidebar)
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, window, ran)
    }

    final class Ran { var items: [String] = [] }

    private static func views(in root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + views(in: $0) } }

    /// Drawn: shown, opaque, with room inside its row.
    private static func drawn(_ view: NSView, in row: NSView) -> Bool {
        !view.isHidden && view.alphaValue > 0 && view.frame.width > 0 && row.bounds.contains(view.frame)
    }

    @Test func theEmptyRowShowsAPlusAtRestThatMakesAWorkspaceInTheGroup() throws {
        let (sidebar, window, ran) = Self.sidebar()
        defer { window.close() }
        let row = try #require(sidebar.list.rowViews[.emptyGroup(Self.group)], "the open empty group shows its row")
        sidebar.list.wire(row, key: .emptyGroup(Self.group))
        row.isHovered = false
        row.layoutSubtreeIfNeeded()
        let plus = try #require(Self.views(in: row).first { $0.accessibilityIdentifier() == "cmux.sidebar.group.grp-empty.emptyAdd" } as? NSButton,
                                "the empty group's row has no + button")
        #expect(Self.drawn(plus, in: row), "the + does not show at rest (user 17912)")
        #expect(plus.accessibilityLabel() == Strings.newWorkspace)
        let center = row.convert(NSPoint(x: plus.frame.midX, y: plus.frame.midY), to: row.superview)
        #expect(row.hitTest(center) === plus, "the + takes no click")
        plus.performClick(nil)
        #expect(ran.items == ["grp-empty workspaceGroup.newWorkspace"], "the + runs New Workspace in Group")
    }

    @Test func theEmptyGroupsHeaderOffersItsPlusOnHover() throws {
        let (sidebar, window, ran) = Self.sidebar()
        defer { window.close() }
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let header = try #require(sidebar.list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
        sidebar.list.wire(header, key: .group(Self.group))
        header.isHovered = true
        header.layoutSubtreeIfNeeded()
        #expect(Self.drawn(header.addButton, in: header), "an empty group's header hides its + on hover")
        #expect(header.addButton.isAccessibilityElement())
        header.addButton.performClick(nil)
        #expect(ran.items == ["grp-empty workspaceGroup.newWorkspace"])
        header.isHovered = false
        header.layoutSubtreeIfNeeded()
        #expect(header.addButton.isHidden, "the header's + stays after the hover ends")
    }
}
