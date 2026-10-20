import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A keyboard selection of Home (Cmd-1) or a wrap to the first workspace (next/previous
/// sidebar tab) scrolls the sidebar to its very top, so the pinned items above the rows show.
@MainActor @Suite(.serialized)
struct SidebarSelectionRevealsTopTests {
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    @Test func topItemsAndTheFirstRowRevealTheTop() {
        let a = WorkspaceID("a"), b = WorkspaceID("b")
        let home = SidebarItem.topItem(LayoutItemID("home"))
        let order = SidebarItemOrder(topItems: [home], rows: [.workspace(a), .workspace(b)])
        #expect(order.revealsTop(for: home))
        #expect(order.revealsTop(for: .workspace(a)))
        #expect(!order.revealsTop(for: .workspace(b)))
        #expect(!order.revealsTop(for: nil))
    }

    /// A document block (a top item drawn in the list) ahead of the workspaces is a row before the
    /// first workspace: that workspace still reveals the top, so the block above it shows. A top item
    /// drawn among the rows below a workspace does not.
    @Test func theFirstWorkspaceBelowAListedBlockRevealsTheTop() {
        let a = WorkspaceID("a"), b = WorkspaceID("b")
        let home = SidebarItem.topItem(LayoutItemID("home")), link = SidebarItem.topItem(LayoutItemID("link"))
        let order = SidebarItemOrder(topItems: [], rows: [home, .workspace(a), link, .workspace(b)])
        #expect(order.revealsTop(for: home))
        #expect(order.revealsTop(for: .workspace(a)))
        #expect(!order.revealsTop(for: link))
        #expect(!order.revealsTop(for: .workspace(b)))
    }

    @Test func theDocumentsTopBlockKeepsTheFirstWorkspaceRevealingTheTop() throws {
        let machine = Self.sections([1, 2, 3])
        let ids = try #require(machine.first?.workspaces.map(\.id))
        let block = CmuxNextSidebar.SidebarSection(
            kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue, title: "", showsTitle: false)), nodes: [])
        let model = SidebarModel(sections: [block] + machine, activeWorkspaceID: ids[1])
        let order = model.itemOrder
        try #require(order.rows.first == .topItem(LayoutItemID("itm_home")), "the top block is not a list row: \(order.rows)")
        #expect(order.revealsTop(for: .workspace(ids[0])), "the first workspace under the top block reveals only its row")
        #expect(!order.revealsTop(for: .workspace(ids[1])))
    }

    @Test func wrappingToTheFirstWorkspaceScrollsToOffsetZero() throws {
        let start = Self.sections(Array(1...40))
        let ids = try #require(start.first?.workspaces.map(\.id))
        let model = SidebarModel(sections: start, activeWorkspaceID: ids[39])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 320)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        defer { window.orderOut(nil) }
        sidebar.layoutSubtreeIfNeeded()
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let list = sidebar.list
        list.reload(animated: false)
        let clip = try #require(list.enclosingScrollView?.contentView)
        let last = try #require(list.displayed.row(for: .workspace(ids[39])))
        list.scrollClip(to: last.y, animated: false)
        try #require(clip.bounds.minY > 50, "the sidebar did not scroll down")

        // The first workspace is in front of every row: offset 0, not just the row's own reveal.
        let old = model.selectedItem, oldSelection = model.selection
        model.activeWorkspaceID = ids[0]
        if !list.patchSelection(from: old, oldSelection: oldSelection) { list.reload(animated: false) }
        #expect(abs(clip.bounds.minY) < 0.5, "the sidebar stayed at \(clip.bounds.minY)")
    }
}
