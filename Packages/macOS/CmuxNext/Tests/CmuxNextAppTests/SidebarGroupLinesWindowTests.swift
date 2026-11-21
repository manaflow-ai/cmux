import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The group rails are made near the visible rows (`SidebarListView.groupLines`), not for every group the list holds,
/// so an apply or a drag's new target costs the rows on screen. Each rail made is the one a pass over every row makes,
/// and a scroll shows the rails of the groups it brings into view.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarGroupLinesWindowTests {
    static func sidebar(_ count: Int) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let groups = stride(from: 0, to: count, by: 10).map { start in
            SidebarNode.group(SidebarGroup(id: GroupID("lw-g\(start)"), name: "Group \(start)", color: .green,
                                           workspaces: (start..<min(count, start + 10)).map {
                                               SidebarWorkspace(id: WorkspaceID("lw-\($0)"), title: "workspace \($0)")
                                           }))
        }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: groups)], activeWorkspaceID: nil)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return (sidebar.list, window)
    }

    /// Every group's rail from a pass over all the rows, by group.
    static func everyRail(_ list: SidebarListView) -> [GroupID: CGRect] {
        let lines = SidebarGroupLine.lines(list.displayed.rows, colors: list.lineColors, nested: !list.legacyNestedRails) { list.frame(for: $0) }
        return Dictionary(lines.map { ($0.group, $0.frame) }, uniquingKeysWith: { first, _ in first })
    }

    /// The groups whose rows the realization rect reaches.
    static func groupsInView(_ list: SidebarListView) -> Set<GroupID> {
        let realize = list.realizationRect()
        return Set(list.displayed.rows.filter { $0.maxY > realize.minY && $0.y < realize.maxY }.compactMap(\.group))
    }

    @Test func theRailsAreTheOnesNearTheRowsAndEachIsTheFullPassRail() throws {
        let (list, window) = Self.sidebar(1000)
        defer { window.close() }
        let every = Self.everyRail(list)
        let shown = list.groupLineViews.shown
        #expect(shown.count < 30, "\(shown.count) of \(every.count) groups have a rail view")
        for (group, line) in shown {
            #expect(line.frame == every[group], "group \(group): \(line.frame) is not the full pass's \(String(describing: every[group]))")
        }
        for group in Self.groupsInView(list) { #expect(shown[group] != nil, "group \(group) in view has no rail") }

        let scroll = try #require(list.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: list.frame.height / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        list.realizeVisibleRows()
        let scrolled = list.groupLineViews.shown
        let inView = Self.groupsInView(list)
        #expect(!inView.isEmpty)
        for group in inView {
            #expect(scrolled[group]?.frame == every[group], "after the scroll, group \(group) shows \(String(describing: scrolled[group]))")
        }
    }
}
