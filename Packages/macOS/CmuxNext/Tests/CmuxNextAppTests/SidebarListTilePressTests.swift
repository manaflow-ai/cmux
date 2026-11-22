import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Live receipt of #22829 on a DEV build (2026-10-21): Home and App Store draw in the list's top block,
/// so a tile drag there is the list's one drag (`dragTile`), not the band's own reorder the band test
/// covers. A press on App Store while a Home drag was still held ended the drag, but Home's slot stayed
/// empty: the tile the drag hid never showed again until something else reloaded the list. Home no longer drags
/// (`LayoutItem.isMovable`, Lawrence 2026-10-30): the dragged tile is the App Store and the press lands on Home.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarListTilePressTests {
    static let home = LayoutItemID("itm_home"), store = LayoutItemID("itm_app_store")
    static let topKey = SidebarRowKey.block(SidebarLayoutDocument.topSectionID.rawValue)

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }

        init() {
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn,
                                    items: [LayoutItem(id: SidebarListTilePressTests.home, ref: SidebarLayoutDocument.homeRef),
                                            LayoutItem(id: SidebarListTilePressTests.store, ref: .app("cmux/app-store"))])
            let block = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue)), nodes: [])
            let members = (1...2).map { SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "w\($0)") }
            let nodes: [SidebarNode] = [.group(SidebarGroup(id: GroupID("grp-work"), name: "Work", workspaces: members))]
            model = SidebarModel(sections: [block, CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: nil)
            model.layout = SidebarLayoutDocument(sections: [top])
            model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in },
                                           adoptRef: { _ in nil })
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 360)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            window.orderFrontRegardless()
            settle()
            list.reload(animated: false)
            settle()
        }

        func settle() {
            sidebar.layoutSubtreeIfNeeded()
            list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
            list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        }

        var region: SidebarRegionView? { (list.rowViews[SidebarListTilePressTests.topKey] as? SidebarBlockRowView)?.region }

        func tile(_ id: LayoutItemID) throws -> SidebarItemRowView {
            let view = try #require(region?.itemView(id), "the top block draws no \(id.rawValue)")
            view.layoutSubtreeIfNeeded()
            return view
        }

        func event(_ type: NSEvent.EventType, on view: NSView, dy: CGFloat = 0) throws -> NSEvent {
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: center.x, y: center.y - dy), modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
    }

    init() { Motion.reduceMotionOverride = true }

    @Test func aPressOnAnotherTileShowsTheTileAStaleDragHid() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.window.close() }
        let store = try h.tile(Self.store)
        store.mouseDown(with: try h.event(.leftMouseDown, on: store))
        store.mouseDragged(with: try h.event(.leftMouseDragged, on: store, dy: 40))
        #expect(h.list.drag != nil, "the fixture's tile drag did not start")

        // The release never came (it went to another window); the next press lands on Home.
        let home = try h.tile(Self.home)
        home.mouseDown(with: try h.event(.leftMouseDown, on: home))
        home.mouseUp(with: try h.event(.leftMouseUp, on: home))
        h.list.endLanding() // the cancelled card lands in the App Store's slot (its flight's completion, now)
        h.settle()

        #expect(h.list.drag == nil, "the stale drag is still held under the new press")
        let shown = try h.tile(Self.store)
        #expect(shown.isDescendant(of: h.window.contentView!), "the App Store's tile left the window")
        #expect(shown.alphaValue == 1, "the App Store's tile stays hidden after the stale drag ended (alpha \(shown.alphaValue))")
        #expect(!shown.isHidden, "the App Store's tile is hidden after the stale drag ended")
    }

    /// The live press landed on the list, not a tile (the drag had moved the rows under the pointer). The list's own
    /// press ends the stale drag (`endPointerGesture`) and the tile the drag hid must show again then too.
    @Test func aPressOnTheListShowsTheTileAStaleDragHid() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.window.close() }
        let store = try h.tile(Self.store)
        let below = try h.event(.leftMouseDown, on: store, dy: 60)
        store.mouseDown(with: try h.event(.leftMouseDown, on: store))
        store.mouseDragged(with: try h.event(.leftMouseDragged, on: store, dy: 40))
        #expect(h.list.drag != nil, "the fixture's tile drag did not start")

        h.list.mouseDown(with: below)
        h.list.mouseUp(with: try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: below.locationInWindow, modifierFlags: [],
                                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
        h.list.endLanding() // the cancelled card lands in the App Store's slot (its flight's completion, now)
        h.settle()

        #expect(h.list.drag == nil, "the stale drag is still held under the new press")
        let shown = try h.tile(Self.store)
        #expect(shown.isDescendant(of: h.window.contentView!), "the App Store's tile left the window")
        #expect(shown.alphaValue == 1, "the App Store's tile stays hidden after the list's press ended the stale drag (alpha \(shown.alphaValue))")
    }
}
