import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-30 on NIGHTLY ("i tried to drag home around and now it's stuck in this state", screenshot): after a
/// drag of Home, Home's slot kept a resting glass card (the drag's lifted pill) over its hidden tile. Home is never
/// draggable: it stays on top, a press-and-drag on it is a no-op (no lift, no drag, no drop, no fill left behind), and a
/// plain click still opens it. A drag released where it started moves nothing, so no card waits on a move that never
/// shows (the settle of Lawrence's drop: Home dropped back into its own section took a new order key, a change that
/// draws nothing new, so nothing ended the settle and its card stayed).
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarHomeDragTests {
    typealias Harness = SidebarHomePinnedDragHarness

    init() { Motion.reduceMotionOverride = true }

    @Test func aPressAndDragOnHomeIsANoOp() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.close() }
        let home = try h.item(Harness.home.id)
        let start = home.convert(NSPoint(x: home.bounds.midX, y: home.bounds.midY), to: nil)
        home.mouseDown(with: try h.mouse(.leftMouseDown, at: start))
        var lifted = false
        // Down over the pinned rows and the list, then back up over Home's own slot.
        for down: CGFloat in [6, 30, 60, 110, 160, 90, 20, 4] {
            home.mouseDragged(with: try h.mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - down)))
            lifted = lifted || h.list.drag != nil || !h.lifts.isEmpty
        }
        home.mouseUp(with: try h.mouse(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 4)))
        h.finishFlights()

        #expect(!lifted, "a press-and-drag on Home lifted it (a drag card and a held drag)")
        #expect(h.drops.isEmpty, "a press-and-drag on Home sent \(h.drops.count) move(s): \(h.drops.map { "\($0.0) -> \($0.1)" })")
        #expect(h.activated == [Harness.home.id], "the press did not open Home exactly once: \(h.activated)")
        h.expectEveryRowAtRest("after a press-and-drag on Home")
        let homeTop = try h.item(Harness.home.id), firstPin = try h.item(Harness.pins[0].id)
        #expect(h.list.convert(homeTop.bounds, from: homeTop).minY < h.list.convert(firstPin.bounds, from: firstPin).minY, "Home is not on top")
    }

    @Test func aClickOnHomeStillOpensIt() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.close() }
        let home = try h.item(Harness.home.id)
        home.mouseDown(with: try h.event(.leftMouseDown, on: home))
        home.mouseUp(with: try h.event(.leftMouseUp, on: home))
        #expect(h.activated == [Harness.home.id], "a click did not open Home once: \(h.activated)")
        h.expectEveryRowAtRest("after a click on Home")
    }

    /// Nothing lands above Home: a pinned row dragged up over Home's top half goes nowhere before it.
    @Test func nothingDropsAboveHome() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.close() }
        let pin = try h.item(Harness.pins[0].id), home = try h.item(Harness.home.id)
        let start = pin.convert(NSPoint(x: pin.bounds.midX, y: pin.bounds.midY), to: nil)
        let above = home.convert(NSPoint(x: home.bounds.midX, y: home.bounds.minY + 2), to: nil)
        pin.mouseDown(with: try h.mouse(.leftMouseDown, at: start))
        for y in stride(from: start.y, through: above.y, by: 4) {
            pin.mouseDragged(with: try h.mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: y)))
        }
        pin.mouseDragged(with: try h.mouse(.leftMouseDragged, at: above))
        pin.mouseUp(with: try h.mouse(.leftMouseUp, at: above))
        h.finishFlights()
        let topSection = SidebarLayoutDocument.topSectionID.rawValue
        for (items, target) in h.drops {
            #expect(target.before != Harness.home.id.rawValue && !(target.section == topSection && target.index == 0 && target.after == nil),
                    "\(items) dropped above Home: \(target)")
        }
        h.expectEveryRowAtRest("after a pinned row dragged up over Home")
    }

    /// A pinned row dragged away and released back on its own slot moves nothing: no move is sent (the document would
    /// take it as a change that shows nothing, and the card would wait on it), and every row is at rest.
    @Test func aDragReleasedWhereItStartedSendsNoMove() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.close() }
        // The middle pinned row: its own slot is between two pinned rows (below the last one, the list's top is the same place).
        let chief = try h.item(Harness.pins[1].id)
        let start = chief.convert(NSPoint(x: chief.bounds.midX, y: chief.bounds.midY), to: nil)
        chief.mouseDown(with: try h.mouse(.leftMouseDown, at: start))
        for down: CGFloat in [8, 24, 40, 24, 8, 1] {
            chief.mouseDragged(with: try h.mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - down)))
        }
        #expect(h.list.drag != nil, "the fixture's pinned drag did not start")
        chief.mouseUp(with: try h.mouse(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 1)))
        h.finishFlights()
        #expect(h.drops.isEmpty, "a drop on the row's own slot sent a move: \(h.drops.map { "\($0.0) -> \($0.1)" })")
        #expect(h.list.settling == nil, "the list still waits on a drop that moves nothing")
        h.expectEveryRowAtRest("after a pinned row released where it started")
    }
}
