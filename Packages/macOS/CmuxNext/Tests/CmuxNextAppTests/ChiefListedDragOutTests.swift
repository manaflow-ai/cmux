import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The Chief dragged beside the sidebar (#23933, Leo 2026-10-21: move it back and forth): from a machine list or a
/// group it comes off only when it is released out there, whatever an autoscroll frame replayed meanwhile. The top
/// rows' tiles: `ChiefTileDragOutTests`.
@MainActor @Suite(.closesItsWindows, .serialized)
struct ChiefListedDragOutTests {
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
                .workspace(ws("w1")), .item(ChiefListedDragOutTests.chief), .workspace(ws("w2")),
            ])], activeWorkspaceID: WorkspaceID("w1"))
            model.layout = SidebarLayoutDocument(sections: [])
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 360)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            window.orderFrontRegardless()
            model.docDrag = SidebarDocDrag(item: { if case let .workspace(id) = $0 { "w_\(id.rawValue)" } else { nil } }, section: { _ in "sec" },
                                           begin: { _ in [:] }, drop: { [weak self] _, target in self?.drops.append(target) })
            sidebar.removesOnDragOut = { $0 == ChiefListedDragOutTests.chief.id }
            sidebar.onDragOutRemove = { [weak self] in self?.removed.append($0) }
            sidebar.renderNow()
            for reload in [false, true] {
                if reload { list.reload(animated: false) }
                sidebar.layoutSubtreeIfNeeded()
                list.fitToClip()
                sidebar.layoutSubtreeIfNeeded()
            }
        }

        /// Presses the Chief's row and lifts it.
        func liftChief() throws {
            let row = try #require(list.displayed.row(for: ChiefListedDragOutTests.chiefKey))
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

    /// Dragged to the bottom edge (autoscroll runs), then past the side: an autoscroll frame replays the last point,
    /// which is out there, so the release removes the Chief and moves nothing.
    @Test func aReleaseBesideTheSidebarRemovesTheChiefAfterAnAutoscrollFrame() throws {
        let h = Harness()
        defer { h.window.closeAfterTest() }
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
        defer { h.window.closeAfterTest() }
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
}
