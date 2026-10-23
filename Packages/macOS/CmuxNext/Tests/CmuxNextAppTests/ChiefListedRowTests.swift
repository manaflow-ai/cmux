import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The Chief listed in a machine list or a group (#23933 review). Its row shows a status or unread change as
/// soon as the App's item info has it, though nothing else changed to reload the list. Dragged beside the
/// sidebar, it comes off only when it is released out there, whatever an autoscroll frame replayed meanwhile.
@MainActor @Suite(.serialized)
struct ChiefListedRowTests {
    static let chief = SidebarListItem(id: "itm_chief", ref: .builtIn(.chief), title: SidebarBuiltIn.chief.title)
    static let chiefKey = SidebarRowKey.item(chief.id)

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var removed: [String] = []
        var drops: [SidebarDocTarget] = []
        var list: SidebarListView { sidebar.list }

        /// The sidebar document's list: `w1`, the Chief and `w2` in this Mac's list; the App removes the Chief on a drag out.
        init() {
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
            model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: [
                .workspace(ws("w1")), .item(ChiefListedRowTests.chief), .workspace(ws("w2")),
            ])], activeWorkspaceID: WorkspaceID("w1"))
            model.layout = SidebarLayoutDocument(sections: [])
            model.itemInfo = [LayoutItemID(ChiefListedRowTests.chief.id): SidebarBuiltIn.chief.defaultInfo]
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 360)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            window.orderFrontRegardless()
            model.docDrag = SidebarDocDrag(item: { key in
                switch key {
                case let .workspace(id): "w_\(id.rawValue)"
                default: nil
                }
            }, section: { _ in "sec" }, begin: { _ in [:] }, drop: { [weak self] _, target in self?.drops.append(target) })
            sidebar.removesOnDragOut = { $0 == ChiefListedRowTests.chief.id }
            sidebar.onDragOutRemove = { [weak self] in self?.removed.append($0) }
            sidebar.renderNow()
            settle()
            list.reload(animated: false)
            settle()
        }

        func settle() {
            sidebar.layoutSubtreeIfNeeded()
            list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
        }

        func chiefRow() throws -> SidebarItemListRowView {
            try #require(list.rowViews[ChiefListedRowTests.chiefKey] as? SidebarItemListRowView, "the list draws no Chief row")
        }

        /// Presses the Chief's row and lifts it.
        func liftChief() throws {
            let row = try #require(list.displayed.row(for: ChiefListedRowTests.chiefKey))
            list.press = SidebarPress(key: row.key, point: NSPoint(x: 80, y: row.y + row.height / 2))
            list.beginDrag(try #require(list.press))
            try #require(list.drag != nil, "the Chief's row did not lift")
        }

        /// A window point `dx` past the sidebar's right edge, at `y`.
        func beside(dx: CGFloat = 60, y: CGFloat) throws -> NSPoint {
            let scroll = try #require(list.enclosingScrollView)
            return NSPoint(x: scroll.convert(scroll.bounds, to: nil).maxX + dx, y: y)
        }

        func release(at windowPoint: NSPoint) throws {
            list.mouseUp(with: try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint, modifierFlags: [],
                                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
            list.endLanding()
        }
    }

    /// The Chief starts waiting with two subagents that need you, then only its conversation is unread: the
    /// App's item info changes and nothing else. The row it already drew shows both, in place.
    @Test func aStatusOrUnreadChangeShowsOnTheListedChiefsRow() throws {
        let h = Harness()
        defer { h.window.orderOut(nil) }
        let row = try h.chiefRow()
        #expect(row.accessibilityValue() as? String == nil)

        var info = SidebarBuiltIn.chief.defaultInfo
        info.activity = .waiting
        info.badge = 2
        h.model.itemInfo[LayoutItemID(Self.chief.id)] = info
        h.sidebar.renderNow()
        h.settle()
        #expect(row.accessibilityValue() as? String == "2", "the Chief's row kept its old badge")

        info.badge = nil
        info.unreadDot = true
        h.model.itemInfo[LayoutItemID(Self.chief.id)] = info
        h.sidebar.renderNow()
        h.settle()
        #expect(row.accessibilityValue() as? String == Strings.unreadDot, "the Chief's row shows no unread dot")
        #expect(try h.chiefRow() === row, "the row was drawn again in a new view, not patched")
    }

    /// The Chief dragged to the bottom edge (autoscroll runs), then past the side: an autoscroll frame re-runs the
    /// drag at the point it last saw (`SidebarDragAutoscroll.tick`). That is the pointer out there, so the release
    /// removes the Chief and moves nothing.
    @Test func aReleaseBesideTheSidebarRemovesTheChiefAfterAnAutoscrollFrame() throws {
        let h = Harness()
        defer { h.window.orderOut(nil) }
        try h.liftChief()
        let clip = try #require(h.list.enclosingScrollView?.contentView)
        let edge = clip.convert(NSPoint(x: 80, y: clip.bounds.maxY - 2), to: nil)
        h.list.updateDrag(windowPoint: edge)
        try #require(h.list.autoscroll.client.isActive, "the bottom edge started no autoscroll")

        let outside = try h.beside(y: edge.y)
        h.list.updateDrag(windowPoint: outside)
        #expect(h.list.drag?.removesOnDrop == true)
        #expect(!h.list.autoscroll.client.isActive, "autoscroll kept running beside the sidebar")
        h.list.updateDrag(windowPoint: try #require(h.list.drag?.lastWindowPoint))
        #expect(h.list.drag?.removesOnDrop == true, "an autoscroll frame took the drag back inside")

        try h.release(at: outside)
        #expect(h.removed == [Self.chief.id])
        #expect(h.drops.isEmpty, "the Chief moved instead: \(h.drops)")
        #expect(h.list.drag == nil)
    }

    /// Dragged beside the sidebar, then released back over the list before any move there: the release decides,
    /// so the Chief stays.
    @Test func aReleaseBackOverTheListKeepsTheChief() throws {
        let h = Harness()
        defer { h.window.orderOut(nil) }
        try h.liftChief()
        let row = try #require(h.list.displayed.row(for: Self.chiefKey))
        let inside = h.list.convert(NSPoint(x: 80, y: row.y + row.height / 2 + 4), to: nil)
        h.list.updateDrag(windowPoint: inside)
        h.list.updateDrag(windowPoint: try h.beside(y: inside.y))
        #expect(h.list.drag?.removesOnDrop == true)

        try h.release(at: inside)
        #expect(h.removed.isEmpty, "a release over the list removed the Chief")
        #expect(h.list.drag == nil)
    }

    /// The older path (no sidebar document): the Chief sits in the top band, drawn by its own region, not the list.
    /// Dragged past the sidebar's side and released there, it comes off as it does from the list (#23933 review).
    @Test func aReleaseBesideTheSidebarRemovesTheChiefFromTheTopBand() throws {
        let chief = LayoutItemID(Self.chief.id)
        let model = SidebarModel(sections: [])
        model.layout = SidebarLayoutDocument(sections: [LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn,
                                                                      items: [LayoutItem(id: chief, ref: .builtIn(.chief))])])
        let sidebar = SidebarView(model: model, design: DesignSettings.shared)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 360)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var removed: [String] = []
        sidebar.removesOnDragOut = { $0 == Self.chief.id }
        sidebar.onDragOutRemove = { removed.append($0) }
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()

        let region = sidebar.aboveRegion
        let tile = try #require(region.itemView(chief), "the top band draws no Chief")
        let start = NSPoint(x: tile.frame.midX, y: tile.frame.midY)
        region.beginDrag(.item(chief), at: start)
        try #require(region.reorder != nil, "the Chief's tile did not lift")
        let beside = NSPoint(x: sidebar.convert(sidebar.bounds, to: nil).maxX + 60, y: region.convert(start, to: nil).y)
        region.updateDrag(to: region.convert(beside, from: nil))
        region.finishDrag()
        #expect(removed == [Self.chief.id], "a release beside the sidebar kept the Chief in the top band")
        #expect(region.reorder == nil)
    }
}
