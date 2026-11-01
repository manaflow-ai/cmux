import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Empty groups show only their header; its hover + keeps New Workspace in Group reachable.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarEmptyGroupAddButtonTests {
    static let group = GroupID("grp-empty")

    /// A sidebar in a window with one open, empty group; `ran` collects the group actions it runs.
    static func sidebar() -> (SidebarView, NSWindow, Ran) {
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

    @Test func theEmptyGroupShowsOnlyItsHeaderAtRest() throws {
        let (sidebar, window, _) = Self.sidebar()
        defer { window.close() }
        let header = try #require(sidebar.list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
        header.isHovered = false
        header.layoutSubtreeIfNeeded()
        #expect(sidebar.list.rowViews[.emptyGroup(Self.group)] == nil)
        #expect(header.addButton.isHidden)
        #expect(!header.isDropTarget)
    }

    @Test func theEmptyHeaderHighlightsOnlyDuringADropIntoIt() throws {
        let (sidebar, window, _) = Self.sidebar()
        defer { window.close() }
        let list = sidebar.list
        let header = try #require(list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
        let source = try #require(list.displayed.row(for: .workspace(WorkspaceID("loose"))))
        let press = SidebarPress(key: source.key, point: NSPoint(x: 80, y: source.y + source.height / 2))
        list.beginDrag(press)
        let drag = try #require(list.drag)
        defer {
            list.cancelDrag()
            if let landing = list.landing { list.finishLand(landing, then: nil) }
        }
        let row = try #require(list.displayed.row(for: .group(Self.group)))
        let y = row.y + row.height / 2
        drag.target = DropResolver.resolve(y: y, payload: .workspaces([WorkspaceID("loose")]),
                                           base: list.displayed, sections: list.model.sections)
        list.syncRowStates()
        #expect(header.isDropTarget)
        drag.target = nil
        list.syncRowStates()
        #expect(!header.isDropTarget)
        #expect(list.rowViews[.emptyGroup(Self.group)] == nil)
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
