import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The sidebar invariant (Lawrence 2026-10-19): "if we focus on workspace, or our
/// focused workspace moves, invariant is it needs to always be in user's sidebar,
/// visible". A selection opens the collapsed section that hides the workspace,
/// and the list scrolls the focused row into view when it moves, by anyone.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarFocusedVisibleTests {
    /// The local machine's section with the workspaces `ids`, in that order.
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    @Test func selectingAWorkspaceInACollapsedSectionOpensIt() throws {
        var start = Self.sections(Array(1...5))
        try #require(!start.isEmpty)
        start[0].isCollapsed = true
        let ids = try #require(start.first?.workspaces.map(\.id))
        let model = SidebarModel(sections: start, activeWorkspaceID: nil)
        try #require(model.collapsedSections.contains(start[0].id))
        model.apply(.select(ids[3]))
        #expect(!model.collapsedSections.contains(start[0].id), "the section that hides the focused workspace stayed collapsed")
        #expect(model.sections.first?.isCollapsed == false)
        // The user can still collapse it while the workspace stays focused.
        model.apply(.toggleCollapse(.section(start[0].id)))
        #expect(model.sections.first?.isCollapsed == true)
    }

    @Test func selectingAWorkspaceInACollapsedDocumentSectionOpensIt() throws {
        let machine = Self.sections(Array(1...3))
        let workspaces = try #require(machine.first?.workspaces)
        let custom = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: "sec-focus", title: "Focus", showsTitle: true)),
                                                    nodes: [.workspace(workspaces[1])])
        let model = SidebarModel(sections: [custom] + machine, activeWorkspaceID: workspaces[0].id)
        model.collapsedLayoutSections = [LayoutSectionID("sec-focus")]
        model.apply(.select(workspaces[1].id))
        #expect(model.collapsedLayoutSections.isEmpty, "the document section that hides the focused workspace stayed collapsed")
    }

    /// A 40-row sidebar in a 240 x 320 window, `ids[0]` focused and in view.
    private static func makeSidebar() throws -> (SidebarModel, SidebarView, NSWindow, [WorkspaceID]) {
        let start = sections(Array(1...40))
        let ids = try #require(start.first?.workspaces.map(\.id))
        let model = SidebarModel(sections: start, activeWorkspaceID: ids[0])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 320)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return (model, sidebar, window, ids)
    }

    private static func isInView(_ list: SidebarListView, _ id: WorkspaceID) throws -> Bool {
        let clip = try #require(list.enclosingScrollView?.contentView)
        let row = try #require(list.displayed.row(for: .workspace(id)))
        return row.y >= clip.bounds.minY - 0.5 && row.y + row.height <= clip.bounds.maxY + 0.5
    }

    @Test func theFocusedRowMovedToTheEndByAnotherClientScrollsIntoView() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (model, sidebar, window, ids) = try Self.makeSidebar()
        defer { window.close() }
        let list = sidebar.list
        try #require(list.enclosingScrollView?.contentView.bounds.height ?? 0 > 0)
        try #require(try Self.isInView(list, ids[0]))
        // The CLI (another client) moves the focused workspace to the end of the list.
        model.sections = Self.sections(Array(2...40) + [1])
        list.reload(animated: false)
        #expect(try Self.isInView(list, ids[0]), "the focused workspace moved out of the sidebar's view")
    }

    @Test func theFocusedRowMovedByADropScrollsIntoView() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (model, sidebar, window, ids) = try Self.makeSidebar()
        defer { window.close() }
        let list = sidebar.list
        try #require(list.enclosingScrollView?.contentView.bounds.height ?? 0 > 0)
        let section = try #require(model.sections.first?.id)
        // As `finishDrag` does: the reveal mark is the active row, then the reorder lands.
        list.revealedActive = .workspace(ids[0])
        model.send(.reorder([ids[0]], to: DropPosition(section: section, index: 39)))
        list.reload(animated: false)
        #expect(try Self.isInView(list, ids[0]), "the dropped focused workspace is out of the sidebar's view")
    }

    @Test func selectingAnOffscreenWorkspaceScrollsItIntoView() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (model, sidebar, window, ids) = try Self.makeSidebar()
        defer { window.close() }
        let list = sidebar.list
        try #require(list.enclosingScrollView?.contentView.bounds.height ?? 0 > 0)
        try #require(try !Self.isInView(list, ids[35]))
        model.apply(.select(ids[35]))
        sidebar.renderNow()
        #expect(try Self.isInView(list, ids[35]), "an off-screen workspace that got focus stayed out of view")
    }
}
