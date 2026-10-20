import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// u2977: the sidebar's top section (Home and the App Store) stays pinned at the top while the
/// workspace list scrolls, on the sidebar document (the app's path, `SidebarModel.docDrag`) too.
/// One owner decides it (`SidebarLayoutDocument.pinnedHeaderSectionID`): `arrange` lists no
/// section for the header, so the list draws no block for it and the band above the list does.
@MainActor @Suite(.serialized)
struct SidebarPinnedHeaderStickyTests {
    static let home = LayoutItemID("itm_home")
    static let appStore = LayoutItemID("itm_app_store")

    private static func machineSections(_ count: Int) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: (1...count).map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    private static func docDrag() -> SidebarDocDrag {
        SidebarDocDrag(item: { key in
            if case let .workspace(id) = key { "w_\(id.rawValue)" } else { nil }
        }, section: { _ in "sec_machine" }, begin: { _ in [:] }, drop: { _, _ in })
    }

    /// The sections the app shows: the machine's rows arranged as the default document places them.
    private static func arranged(_ count: Int, layout: SidebarLayoutDocument = .defaults) -> [CmuxNextSidebar.SidebarSection] {
        var projection = SidebarDocProjection(rows: [], records: SidebarDocRecords(), revision: 0)
        projection.layout = layout
        return projection.arrange(machineSections(count), drag: docDrag())
    }

    /// A 60-row document sidebar in a 240 x 400 window.
    private static func makeSidebar() throws -> (SidebarModel, SidebarView, NSWindow, [WorkspaceID]) {
        let sections = arranged(60)
        let ids = try #require(sections.first { $0.machine != nil }?.workspaces.map(\.id))
        let model = SidebarModel(sections: sections, activeWorkspaceID: ids[0])
        model.docDrag = docDrag()
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (model, sidebar, window, ids)
    }

    /// Home's frame in the window, drawn by the band above the list (not by a list row that scrolls).
    private static func headerFrame(_ sidebar: SidebarView, _ id: LayoutItemID = home) throws -> NSRect {
        let view = try #require(sidebar.aboveRegion.itemView(id), "the band above the list does not draw \(id.rawValue)")
        return view.convert(view.bounds, to: nil)
    }

    /// How far below the sidebar's top edge `frame` (window coordinates, the window's content is not flipped) starts.
    private static func topInset(_ sidebar: SidebarView, _ frame: NSRect, height: CGFloat? = nil) -> CGFloat {
        let top = sidebar.convert(NSPoint(x: 0, y: sidebar.isFlipped ? 0 : sidebar.bounds.height), to: nil).y
        return top + (height.map { $0 - sidebar.bounds.height } ?? 0) - frame.maxY
    }

    private static func expectSame(_ a: NSRect, _ b: NSRect, _ what: String) {
        #expect(abs(a.minY - b.minY) < 0.5 && abs(a.height - b.height) < 0.5, "Home moved after \(what): \(a) -> \(b)")
    }

    @Test func theHeaderIsNoListSectionAndItsItemsAreTopItems() {
        let sections = Self.arranged(3)
        #expect(!sections.contains { $0.id == .custom(SidebarLayoutDocument.topSectionID.rawValue) },
                "the top section is a list section, so it scrolls with the rows: \(sections.map(\.id))")
        let model = SidebarModel(sections: sections, activeWorkspaceID: nil)
        #expect(model.itemOrder.topItems == [.topItem(Self.home), .topItem(Self.appStore)], "top items: \(model.itemOrder.topItems)")
    }

    /// A section holding a group lists its rows, so it stays a list section (the rule's one exception).
    @Test func aGroupedTopSectionStaysInTheList() {
        let layout = SidebarLayoutDocument.defaults
        #expect(layout.pinnedHeaderSectionID(grouped: []) == SidebarLayoutDocument.topSectionID)
        #expect(layout.pinnedHeaderSectionID(grouped: [SidebarLayoutDocument.topSectionID.rawValue]) == nil)
    }

    @Test func homeStaysAtTheTopWhileTheListScrolls() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (model, sidebar, window, ids) = try Self.makeSidebar()
        defer { window.orderOut(nil) }
        let list = sidebar.list
        let clip = try #require(list.enclosingScrollView?.contentView)
        #expect(list.displayed.row(for: .block(SidebarLayoutDocument.topSectionID.rawValue)) == nil, "the list draws the header as a row")
        let start = try Self.headerFrame(sidebar)
        let storeStart = try Self.headerFrame(sidebar, Self.appStore)

        // Scroll the list to its end: the header does not move.
        list.scrollClip(to: list.displayed.totalHeight, animated: false)
        sidebar.layoutSubtreeIfNeeded()
        try #require(clip.bounds.minY > 200, "the list did not scroll: \(clip.bounds.minY)")
        Self.expectSame(start, try Self.headerFrame(sidebar), "a scroll")
        Self.expectSame(storeStart, try Self.headerFrame(sidebar, Self.appStore), "a scroll (App Store)")

        // Cmd-2 (a workspace selection), then Cmd-1 (Home).
        let old = model.selectedItem, oldSelection = model.selection
        model.activeWorkspaceID = ids[30]
        if !list.patchSelection(from: old, oldSelection: oldSelection) { list.reload(animated: false) }
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        Self.expectSame(start, try Self.headerFrame(sidebar), "a workspace selection")
        model.selectedItem = .topItem(Self.home)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        Self.expectSame(start, try Self.headerFrame(sidebar), "selecting Home")

        // A resize.
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 300)
        sidebar.layoutSubtreeIfNeeded()
        list.scrollClip(to: list.displayed.totalHeight, animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let resized = try Self.headerFrame(sidebar)
        #expect(abs(Self.topInset(sidebar, resized) - Self.topInset(sidebar, start, height: 400)) < 0.5,
                "the header left the top after a resize: \(start) -> \(resized)")
        #expect(clip.convert(clip.bounds, to: nil).maxY <= resized.minY + 0.5, "the list draws over the header after a resize")
    }
}
