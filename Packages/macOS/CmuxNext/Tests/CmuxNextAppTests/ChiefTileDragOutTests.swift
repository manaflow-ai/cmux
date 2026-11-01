import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The Chief as a tile (#23933 review), in the list's top block or the older top band: dragged past the sidebar's
/// side, the release decides. Back over the sidebar the Chief stays; out there it comes off.
@MainActor @Suite(.closesItsWindows, .serialized)
struct ChiefTileDragOutTests {
    static let chief = LayoutItemID("itm_chief"), home = LayoutItemID("itm_home")
    static let topKey = SidebarRowKey.block(SidebarLayoutDocument.topSectionID.rawValue)

    /// A window with a sidebar whose top rows hold the Chief and Home. `document`: the list draws them as its
    /// top block (the sidebar document); else the older top band draws them.
    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var removed: [String] = []
        let document: Bool
        var list: SidebarListView { sidebar.list }

        init(document: Bool) {
            self.document = document
            let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn,
                                    items: [LayoutItem(id: ChiefTileDragOutTests.chief, ref: .builtIn(.chief)),
                                            LayoutItem(id: ChiefTileDragOutTests.home, ref: SidebarLayoutDocument.homeRef)])
            if document {
                let block = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue)), nodes: [])
                let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
                let members = (1...2).map { SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "w\($0)") }
                model = SidebarModel(sections: [block, CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: members.map(SidebarNode.workspace))],
                                     activeWorkspaceID: nil)
                model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in },
                                               adoptRef: { _ in nil })
            } else {
                model = SidebarModel(sections: [])
            }
            model.layout = SidebarLayoutDocument(sections: [top])
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 360)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            window.orderFrontRegardless()
            sidebar.removesOnDragOut = { $0 == ChiefTileDragOutTests.chief.rawValue }
            sidebar.onDragOutRemove = { [weak self] in self?.removed.append($0) }
            sidebar.renderNow()
            settle()
            if document { list.reload(animated: false); settle() }
        }

        func settle() {
            sidebar.layoutSubtreeIfNeeded()
            list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
            list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        }

        var region: SidebarRegionView? {
            document ? (list.rowViews[ChiefTileDragOutTests.topKey] as? SidebarBlockRowView)?.region : sidebar.aboveRegion
        }

        func tile() throws -> SidebarItemRowView {
            let view = try #require(region?.itemView(ChiefTileDragOutTests.chief), "the top rows draw no Chief tile")
            view.layoutSubtreeIfNeeded()
            return view
        }

        /// Whether the drag in flight says a release now removes the Chief.
        var removesOnDrop: Bool? { document ? list.drag?.removesOnDrop : region?.reorder?.removesOnDrop }
        var dragging: Bool { document ? list.drag != nil : region?.reorder != nil }

        func event(_ type: NSEvent.EventType, at windowPoint: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        /// Presses the Chief's tile, drags it down past the threshold, then out past the sidebar's right side.
        /// Returns the tile and the window point it was pressed at.
        func dragChiefOut() throws -> (SidebarItemRowView, NSPoint) {
            let tile = try tile()
            let center = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
            tile.mouseDown(with: try event(.leftMouseDown, at: center))
            tile.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: center.x, y: center.y - 30)))
            try #require(dragging, "the Chief's tile did not lift")
            let beside = NSPoint(x: sidebar.convert(sidebar.bounds, to: nil).maxX + 60, y: center.y)
            tile.mouseDragged(with: try event(.leftMouseDragged, at: beside))
            try #require(removesOnDrop == true, "the Chief beside the sidebar does not show it comes off")
            return (tile, center)
        }

        func finish() {
            list.endLanding()
            region?.layoutSubtreeIfNeeded()
        }
    }

    init() { Motion.reduceMotionOverride = true }

    /// Dragged out, then released through the tile's own mouse-up: the release decides. Back over its own slot (no
    /// move in between) the Chief stays; out there it comes off.
    @Test(arguments: [true, false], [true, false])
    func aTileReleaseDecides(document: Bool, beside: Bool) throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(document: document)
        defer { h.window.closeAfterTest() }
        let (tile, inside) = try h.dragChiefOut()
        let release = beside ? NSPoint(x: h.sidebar.convert(h.sidebar.bounds, to: nil).maxX + 80, y: inside.y) : inside
        tile.mouseUp(with: try h.event(.leftMouseUp, at: release))
        h.finish()
        #expect(h.removed == (beside ? [Self.chief.rawValue] : []), "\(document ? "document list" : "top band"), beside: \(beside)")
        #expect(!h.dragging)
    }

    /// Dragged out and released over another cmux window or the desktop: that window gets the release, never the
    /// tile. The list (`pointerEventSeen`) or the older top band (`releaseSeen`) ends the drag once its dispatch is
    /// over, and the release point still decides: beside the sidebar the Chief comes off, back over it it stays. The
    /// band's drag must not stay lifted with its tile hidden.
    @Test(arguments: [true, false], [true, false])
    func aReleaseSentToAnotherWindowStillDecides(document: Bool, beside: Bool) async throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(document: document)
        defer { h.window.closeAfterTest() }
        let (_, inside) = try h.dragChiefOut()
        let other = NSWindow(contentRect: NSRect(x: 900, y: 200, width: 200, height: 200), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let release = h.window.convertPoint(toScreen: beside ? NSPoint(x: h.sidebar.convert(h.sidebar.bounds, to: nil).maxX + 80, y: inside.y) : inside)
        if document {
            h.list.leftButtonIsDown = { false }
            #expect(!h.list.pointerEventSeen(.leftMouseUp, in: other, at: release))
        } else {
            try #require(h.region).releaseSeen(in: other, at: release)
        }
        await RapidWorkspaceCreateTests.wait(within: .seconds(2)) { !h.dragging }
        h.finish()
        #expect(h.removed == (beside ? [Self.chief.rawValue] : []), "\(document ? "document list" : "top band"), beside: \(beside)")
        #expect(!h.dragging, "the drag stayed alive after its release went to another window")
    }

    /// The sidebar leaves its window mid-drag: the band's drag ends with it (no release can reach it), its release
    /// monitor goes, its card leaves and the Chief's tile shows again; nothing is removed.
    @Test func aBandDragEndsWhenTheSidebarLeavesItsWindow() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(document: false)
        defer { h.window.closeAfterTest() }
        _ = try h.dragChiefOut()
        let region = try #require(h.region)
        let drag = try #require(region.reorder, "the band holds no drag")
        try #require(drag.pointerEnd != nil, "the band's drag watches no release")
        h.sidebar.removeFromSuperview()
        #expect(drag.pointerEnd == nil, "the band's release monitor outlived its window")
        #expect(region.reorder == nil, "the band's drag outlived its window")
        #expect(drag.hidden.allSatisfy { $0.alphaValue == 1 }, "the Chief's tile stayed hidden under a card that is gone")
        #expect(drag.lift.superview == nil, "the drag's card stayed up")
        #expect(h.removed.isEmpty, "leaving the window removed the Chief")
    }
}
