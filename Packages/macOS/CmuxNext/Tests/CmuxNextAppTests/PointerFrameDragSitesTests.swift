import AppKit
import CmuxNextInput
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

private typealias StripTab = CmuxNextTabs.TabID

/// The reorder drags left on per-event work at the close of MQ-pointer-per-event move once per frame
/// on their window's drag frames (``PointerFrameDrag``, feature `pointerFrameDrags`): a space dot, a pinned sidebar item and section header, a sidebar list row and a tab. The drag's start acts on its own
/// event; after it, a frame interval's first event moves at once and the rest once at the frame, at the latest
/// point, as Chromium delivers rAF-aligned moves (main_thread_event_queue.cc); the release lands the pending point.
@MainActor @Suite(.serialized) struct PointerFrameDragSitesTests {
    final class DragFramesWindow: NSWindow, DragFrameInputHosting {
        var dragFrameInput: FrameInputCoalescers?
    }

    final class Rig {
        let frames = FrameInputTestRig()
        let window: DragFramesWindow

        init(width: CGFloat, height: CGFloat) {
            _ = NSApplication.shared
            window = DragFramesWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.dragFrameInput = frames.coalescers
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        }

        var content: NSView { window.contentView! }

        /// The event `type` at `point` (window coordinates).
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        func tearDown() {
            frames.close()
            window.orderOut(nil)
            window.close()
        }
    }

    // MARK: - Space dots

    @Test func aDraggedSpaceDotMovesTwiceAFrameAndDropsWhereItEnded() throws {
        let rig = Rig(width: 240, height: 28)
        defer { rig.tearDown() }
        let keys = (0..<3).map { ProfileKey("space\($0)") }
        let model = SidebarModel()
        model.profiles = keys.enumerated().map { SidebarProfile(id: $1, name: "Space \($0)") }
        model.activeProfileID = keys[0]
        let bar = ProfileBarView(model: model)
        bar.frame = rig.content.bounds
        rig.content.addSubview(bar)
        bar.layoutSubtreeIfNeeded()
        bar.refresh()
        var reorders: [SidebarIntent] = []
        model.onIntent = { [unowned model, unowned bar] intent in
            if case .reorderProfile = intent { reorders.append(intent) }
            model.apply(intent)
            bar.refresh()
        }
        func center(_ index: Int) -> NSPoint {
            let slot = bar.slotRects()[index]
            return bar.convert(NSPoint(x: slot.midX, y: slot.midY), to: nil)
        }
        let y = center(0).y

        bar.mouseDown(with: try rig.event(.leftMouseDown, center(0)))
        bar.mouseDragged(with: try rig.event(.leftMouseDragged, NSPoint(x: center(1).x + 2, y: y)))
        #expect(bar.previewOrder == [keys[1], keys[0], keys[2]], "the frame's first event moves the dot at once")
        for dx in [4.0, 6, 8] { bar.mouseDragged(with: try rig.event(.leftMouseDragged, NSPoint(x: center(1).x + dx, y: y))) }
        bar.mouseDragged(with: try rig.event(.leftMouseDragged, NSPoint(x: center(2).x + 4, y: y)))
        #expect(bar.previewOrder == [keys[1], keys[0], keys[2]], "later events wait for the frame")
        #expect(bar.dotMoves.hasPending)

        rig.frames.frame()
        #expect(bar.previewOrder == [keys[1], keys[2], keys[0]])
        #expect(bar.dotMoves.maxDeliveriesPerFrame <= 2)

        bar.mouseUp(with: try rig.event(.leftMouseUp, NSPoint(x: center(2).x + 4, y: y)))
        #expect(reorders == [.reorderProfile(keys[0], index: 3)], "\(reorders)")
    }

    // MARK: - Pinned sidebar items and section headers

    @Test func aPinnedItemDragMovesTheRegionTwiceAFrame() throws {
        let rig = Rig(width: 240, height: 700)
        defer { rig.tearDown() }
        let id = LayoutItemID("itm_home")
        let section = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn,
                                    items: [LayoutItem(id: id, ref: SidebarLayoutDocument.homeRef)])
        let region = SidebarRegionView(region: .top)
        region.frame = NSRect(x: 0, y: 0, width: 240, height: 660)
        region.update(SidebarRegionView.Content(sections: [section], infos: [:], collapsed: [], look: SidebarSectionTunables.currentLook,
                                                metrics: .standard, drawsLines: false), width: 240)
        rig.content.addSubview(region)
        region.layoutSubtreeIfNeeded()
        let row = try #require(region.itemView(id))
        row.layoutSubtreeIfNeeded()
        var points: [CGFloat] = []
        var ended = 0
        row.onDragged = { _, point in points.append(point.y); return true }
        row.onDragEnded = { ended += 1 }
        let start = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        func at(_ dy: CGFloat) -> NSPoint { NSPoint(x: start.x, y: start.y + dy) }

        row.mouseDown(with: try rig.event(.leftMouseDown, at(0)))
        row.mouseDragged(with: try rig.event(.leftMouseDragged, at(30)))
        for dy in stride(from: 40.0, through: 90.0, by: 10) { row.mouseDragged(with: try rig.event(.leftMouseDragged, at(dy))) }
        #expect(points == [start.y + 30, start.y + 40], "the start, then the frame's first event; the rest wait")
        rig.frames.frame()
        #expect(points == [start.y + 30, start.y + 40, start.y + 90])
        #expect(row.dragMoves.maxDeliveriesPerFrame <= 2)

        row.mouseDragged(with: try rig.event(.leftMouseDragged, at(100)))
        row.mouseDragged(with: try rig.event(.leftMouseDragged, at(110)))
        row.mouseUp(with: try rig.event(.leftMouseUp, at(110)))
        #expect(points.last == start.y + 110, "the release lands the pending point before the drop")
        #expect(ended == 1)
    }

    @Test func aSectionHeaderDragMovesTheRegionTwiceAFrame() throws {
        let rig = Rig(width: 240, height: 300)
        defer { rig.tearDown() }
        let header = SidebarSectionHeaderView()
        header.frame = NSRect(x: 0, y: 100, width: 240, height: 28)
        rig.content.addSubview(header)
        var points: [CGFloat] = []
        var ended = 0
        header.onDragged = { _, point in points.append(point.y); return true }
        header.onDragEnded = { ended += 1 }
        let start = header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: nil)
        func at(_ dy: CGFloat) -> NSPoint { NSPoint(x: start.x, y: start.y + dy) }

        header.mouseDown(with: try rig.event(.leftMouseDown, at(0)))
        for dy in stride(from: 10.0, through: 80.0, by: 10) { header.mouseDragged(with: try rig.event(.leftMouseDragged, at(dy))) }
        #expect(points == [start.y + 10, start.y + 20])
        rig.frames.frame()
        #expect(points == [start.y + 10, start.y + 20, start.y + 80])
        #expect(header.dragMoves.maxDeliveriesPerFrame <= 2)
        header.mouseUp(with: try rig.event(.leftMouseUp, at(80)))
        #expect(ended == 1)
    }

    // MARK: - Sidebar list rows

    @Test func aLiftedListRowFollowsThePointerTwiceAFrame() throws {
        let rig = Rig(width: 240, height: 600)
        defer { rig.tearDown() }
        let (list, plain) = SidebarPointerGestureTests.list()
        plain.close()
        list.removeFromSuperview()
        list.frame = rig.content.bounds
        rig.content.addSubview(list)
        rig.window.orderFrontRegardless()
        list.reload(animated: false)
        let order = SidebarPointerGestureTests.ids(list)
        let start = try SidebarPointerGestureTests.point(list, .workspace(WorkspaceID("x")))
        func at(_ dy: CGFloat) throws -> NSEvent {
            try SidebarPointerGestureTests.event(list, .leftMouseDragged, at: NSPoint(x: start.x, y: start.y + dy))
        }

        list.mouseDown(with: try SidebarPointerGestureTests.event(list, .leftMouseDown, at: start))
        var dy: CGFloat = 0
        while list.drag == nil, dy < 60 {
            dy += 10
            list.mouseDragged(with: try at(dy))
        }
        let drag = try #require(list.drag, "a 60 pt move did not lift the row")
        let lifted = drag.lastWindowPoint
        for step in 1...6 { list.mouseDragged(with: try at(dy + CGFloat(step) * 10)) }
        #expect(drag.lastWindowPoint == lifted, "the drags after the lift's frame wait for the frame")
        #expect(list.dragMoves.hasPending)

        rig.frames.frame()
        #expect(drag.lastWindowPoint == list.convert(NSPoint(x: start.x, y: start.y + dy + 60), to: nil))
        #expect(list.dragMoves.maxDeliveriesPerFrame <= 2)

        list.mouseDragged(with: try at(dy + 70))
        list.mouseDragged(with: try at(dy + 80))
        list.mouseUp(with: try SidebarPointerGestureTests.event(list, .leftMouseUp, at: NSPoint(x: start.x, y: start.y + dy + 80)))
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        #expect(list.drag == nil && list.press == nil)
        #expect(!list.dragMoves.hasPending)
        #expect(SidebarPointerGestureTests.ids(list) != order, "the drop moved nothing: \(SidebarPointerGestureTests.ids(list))")
    }

    // MARK: - Tab strip

    @Test func aDraggedTabFollowsThePointerTwiceAFrameAndDropsWhereItEnded() throws {
        let rig = Rig(width: 900, height: 40)
        defer { rig.tearDown() }
        let model = TabStripModel(tabs: (0..<6).map { TabItem(id: StripTab("t\($0)"), title: "Tab \($0)") }, selectedID: StripTab("t1"))
        let strip = TabStripView.testing(model: model)
        strip.dragsWindowFromEmptySpace = false
        strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
        rig.content.addSubview(strip)
        rig.window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        var intents: [TabStripIntent] = []
        model.intentHandler = { [unowned model] intent in
            intents.append(intent)
            if case .select(let id) = intent { model.selectedID = id }
        }
        func point(_ id: String, dx: CGFloat = 12) throws -> CGPoint {
            let cell = try #require(strip.cells[StripTab(id)], "no cell for \(id)")
            return strip.convert(strip.convert(CGPoint(x: cell.frame.minX + dx, y: cell.frame.midY), from: strip.tabsClip), to: nil)
        }
        let start = try point("t1")
        let end = try point("t5", dx: 80)
        func at(_ x: CGFloat) throws -> NSEvent { try rig.event(.leftMouseDragged, CGPoint(x: x, y: start.y)) }

        strip.mouseDown(with: try rig.event(.leftMouseDown, start))
        var x = start.x
        while strip.drag == nil, x < start.x + 60 {
            x += 10
            strip.mouseDragged(with: try at(x))
        }
        let lifted = try #require(strip.drag, "a 60 pt move did not lift the tab").lastPoint
        // The frame's first event after the lift moves at once; the rest wait.
        strip.mouseDragged(with: try at(x + 10))
        let leading = try #require(strip.drag).lastPoint
        #expect(leading != lifted)
        for step in 1...6 { strip.mouseDragged(with: try at(x + 10 + (end.x - x - 10) * CGFloat(step) / 6)) }
        #expect(strip.drag?.lastPoint == leading, "the drags after the frame's first wait for the frame")
        #expect(strip.dragMoves.hasPending)

        rig.frames.frame()
        #expect(strip.drag?.lastPoint == strip.convert(CGPoint(x: end.x, y: start.y), from: nil))
        #expect(strip.dragMoves.maxDeliveriesPerFrame <= 2)

        strip.mouseUp(with: try rig.event(.leftMouseUp, CGPoint(x: end.x, y: start.y)))
        let reorders = intents.compactMap { intent -> StripTab? in if case .reorder(let id, _, _) = intent { id } else { nil } }
        #expect(reorders == [StripTab("t1")], "\(intents)")
        #expect(strip.presentedTabIDs.last == StripTab("t1"))
    }
}
