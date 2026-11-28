import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar list's passes over its realized rows read the row inset once (CMUX NEXT Stable perf gate). The inset is
/// derived from the density, the text size and the glyph size on every read, and a row's frame read it four to six
/// times. In the fleet's traces of a 400-workspace sidebar with 15 agents ticking, `realizeVisibleRows` and its prune
/// spent nearly all their time there: 213 of 242 samples across the workspace switch matrix, 68 of 77 while ticking.
@MainActor @Suite struct SidebarRowGeometryTests {
    struct Harness {
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }
    }

    /// `count` workspaces: four groups of three first (headers that reach over their rails, and members), then loose
    /// rows, in a sidebar 900 pt tall.
    static func make(_ count: Int) -> Harness {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ids = (0..<count).map { WorkspaceID("geo-\($0)") }
        let ws = { (id: WorkspaceID) in SidebarWorkspace(id: id, title: id.rawValue) }
        var nodes: [SidebarNode] = (0..<4).map { g in
            SidebarNode.group(SidebarGroup(id: GroupID("geo-g\(g)"), name: "Group \(g)", color: .green,
                                workspaces: ids[g * 3..<g * 3 + 3].map(ws)))
        }
        nodes += ids[12...].map { SidebarNode.workspace(ws($0)) }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: ids.first)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        return Harness(sidebar: sidebar, window: window)
    }

    @Test func aPassOverTheRealizedRowsReadsTheInsetOnce() throws {
        let h = Self.make(400)
        defer { h.window.close() }
        let realized = h.list.rowViews.count
        try #require(realized >= 20, "only \(realized) rows realized")
        let before = h.list.insetReads
        h.list.realizeVisibleRows()
        let reads = h.list.insetReads - before
        #expect(reads <= 1, "a pass over \(realized) realized rows read the row inset \(reads) times")
    }

    /// Every realized row sits at its own frame after a width change, read again for the new width, as before.
    @Test(arguments: [320.0, 200.0, 260.0])
    func aWidthChangePlacesEveryRealizedRowAtItsFrame(_ width: CGFloat) throws {
        let h = Self.make(400)
        defer { h.window.close() }
        h.window.setContentSize(NSSize(width: width, height: 900))
        h.sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        h.sidebar.layoutSubtreeIfNeeded()
        let list = h.list
        try #require(!list.rowViews.isEmpty)
        var checked = 0
        for (key, view) in list.rowViews {
            guard let row = list.displayed.row(for: key), !view.isHidden else { continue }
            #expect(view.frame == list.drawnFrame(for: row), "\(key) at \(view.frame), its frame is \(list.drawnFrame(for: row))")
            checked += 1
        }
        #expect(checked >= 20, "only \(checked) rows checked at width \(width)")
    }
}
