import CoreGraphics
import Testing
@testable import CmuxNextBridge

/// DRAG-SHAPE-INVARIANT: over an in-place surface the dragged tab or
/// workspace keeps its shape; outside every one it is the preview card; the
/// switch happens at one boundary both ways and never flickers.
struct DragShapeTests {
    /// A strip 400 x 30 at (100, 500); it hit-tests 16 pt above and below
    /// itself (its own slop) and lets go 40 pt past itself (tear-off).
    let strip = DragShapeTarget(key: "strip-a", bounds: CGRect(x: 100, y: 500, width: 400, height: 30), axis: .horizontal,
                                leaveMargin: 40)
    let stripB = DragShapeTarget(key: "strip-b", bounds: CGRect(x: 100, y: 200, width: 400, height: 30), axis: .horizontal,
                                 leaveMargin: 40)
    /// A sidebar list 240 wide; lets go 24 pt past its sides.
    let sidebar = DragShapeTarget(key: "sidebar-w1", bounds: CGRect(x: 0, y: 0, width: 240, height: 800), axis: .vertical,
                                  leaveMargin: 24)
    let slop: CGFloat = 16

    /// The surface's own hit test: inside its x span, within `slop` vertically.
    func answer(_ target: DragShapeTarget, at point: CGPoint, accepts: Bool = true) -> DragShapeAnswer? {
        let b = target.bounds
        guard point.x >= b.minX, point.x <= b.maxX, point.y >= b.minY - slop, point.y <= b.maxY + slop else { return nil }
        return DragShapeAnswer(target: target, slot: CGRect(x: point.x - 60, y: b.minY, width: 120, height: b.height), accepts: accepts)
    }

    /// One pointer move as the drag session runs it: the held surface first
    /// while inside its leave band, else every surface in order.
    func move(_ machine: inout DragShapeMachine, to point: CGPoint, surfaces: [DragShapeTarget]) -> DragShape {
        if let probe = machine.stickyProbe(point), let held = answer(probe.target, at: probe.point) {
            return machine.resolve(held)
        }
        let hit = surfaces.lazy.compactMap { answer($0, at: point) }.first
        return machine.resolve(hit)
    }

    @Test func outsideEverySurfaceIsTheCard() {
        var machine = DragShapeMachine()
        #expect(move(&machine, to: CGPoint(x: 900, y: 900), surfaces: [strip]) == .card)
        #expect(machine.held == nil)
    }

    @Test func overAStripTheTabKeepsItsShape() {
        var machine = DragShapeMachine()
        let shape = move(&machine, to: CGPoint(x: 300, y: 515), surfaces: [strip])
        #expect(shape.isInPlace)
        #expect(machine.held == strip)
        guard case .inPlace(let target, let slot) = shape else { return }
        #expect(target == strip)
        #expect(slot.minY == strip.bounds.minY)
    }

    @Test func aRefusedPlaceIsTheCard() {
        var machine = DragShapeMachine()
        _ = move(&machine, to: CGPoint(x: 300, y: 515), surfaces: [strip])
        let refused = answer(strip, at: CGPoint(x: 300, y: 515), accepts: false)
        #expect(machine.resolve(refused) == .card)
        #expect(machine.held == nil)
    }

    /// The tab stays in its strip until the pointer is the strip's own
    /// tear-off distance away, exactly as the in-strip drag does before its
    /// hand-off, then turns into the card.
    @Test func leavingUsesTheSurfacesOwnLeaveMargin() {
        var machine = DragShapeMachine()
        _ = move(&machine, to: CGPoint(x: 300, y: 515), surfaces: [strip])
        // 30 pt below the strip: past the 16 pt slop, inside the 40 pt band.
        #expect(move(&machine, to: CGPoint(x: 300, y: 470), surfaces: [strip]).isInPlace)
        // Above the top, beside the end: still inside the band.
        #expect(move(&machine, to: CGPoint(x: 300, y: 565), surfaces: [strip]).isInPlace)
        #expect(move(&machine, to: CGPoint(x: 530, y: 515), surfaces: [strip]).isInPlace)
        // 45 pt below: out.
        #expect(move(&machine, to: CGPoint(x: 300, y: 455), surfaces: [strip]) == .card)
        #expect(machine.held == nil)
    }

    @Test func theStickyProbeClampsThePointIntoTheHeldSurface() throws {
        var machine = DragShapeMachine()
        _ = move(&machine, to: CGPoint(x: 300, y: 515), surfaces: [strip])
        let probe = try #require(machine.stickyProbe(CGPoint(x: 530, y: 460)))
        #expect(probe.target == strip)
        #expect(strip.bounds.contains(probe.point))
        #expect(machine.stickyProbe(CGPoint(x: 300, y: 400)) == nil)
    }

    /// Coming back from the card the tab takes the strip where the strip's
    /// own hit test takes it (its slop), not at the wider leave band.
    @Test func enteringUsesTheSurfacesOwnHitTest() {
        var machine = DragShapeMachine()
        #expect(move(&machine, to: CGPoint(x: 300, y: 470), surfaces: [strip]) == .card)
        #expect(machine.stickyProbe(CGPoint(x: 300, y: 470)) == nil)
        #expect(move(&machine, to: CGPoint(x: 300, y: 488), surfaces: [strip]).isInPlace)
    }

    /// A pointer jittering on the strip's edge does not switch shape on
    /// every event: one switch in, one out once it really leaves.
    @Test func noFlickerAtTheBoundary() {
        var machine = DragShapeMachine()
        var shapes: [Bool] = []
        let ys: [CGFloat] = [470, 486, 482, 486, 480, 486, 478, 484, 470, 465, 470, 455, 457, 455]
        for y in ys { shapes.append(move(&machine, to: CGPoint(x: 300, y: y), surfaces: [strip]).isInPlace) }
        let switches = zip(shapes, shapes.dropFirst()).filter { $0 != $1 }.count
        #expect(switches == 2)
        #expect(shapes.first == false)
        #expect(shapes.last == false)
    }

    @Test func movingToAnotherStripMovesTheInPlaceTarget() {
        var machine = DragShapeMachine()
        _ = move(&machine, to: CGPoint(x: 300, y: 515), surfaces: [strip, stripB])
        #expect(move(&machine, to: CGPoint(x: 300, y: 350), surfaces: [strip, stripB]) == .card)
        let shape = move(&machine, to: CGPoint(x: 300, y: 215), surfaces: [strip, stripB])
        guard case .inPlace(let target, _) = shape else {
            Issue.record("expected in place over strip B, got \(shape)")
            return
        }
        #expect(target == stripB)
    }

    @Test func escapeResetsToTheCard() {
        var machine = DragShapeMachine()
        _ = move(&machine, to: CGPoint(x: 300, y: 515), surfaces: [strip])
        machine.reset()
        #expect(machine.shape == .card)
        #expect(machine.held == nil)
        #expect(machine.stickyProbe(CGPoint(x: 300, y: 515)) == nil)
    }

    @Test func aWorkspaceOverASidebarKeepsItsRowShape() {
        var machine = DragShapeMachine()
        let shape = move(&machine, to: CGPoint(x: 120, y: 400), surfaces: [sidebar])
        #expect(shape.isInPlace)
        // 20 pt past the side: still in the list (side slack 24).
        #expect(move(&machine, to: CGPoint(x: 260, y: 400), surfaces: [sidebar]).isInPlace)
        #expect(move(&machine, to: CGPoint(x: 270, y: 400), surfaces: [sidebar]) == .card)
    }

    // MARK: Geometry

    let row = CGSize(width: 220, height: 32)

    @Test func cardRectKeepsTheGrabPointUnderThePointer() {
        let rect = DragShapeMachine.itemRect(.card, pointer: CGPoint(x: 700, y: 300), grabOffset: CGPoint(x: 50, y: 10), itemSize: row)
        #expect(rect == CGRect(x: 650, y: 290, width: 220, height: 32))
    }

    /// In a strip the tab follows the pointer sideways at the slot's row
    /// and size.
    @Test func horizontalInPlaceRectSitsOnTheSlotRow() {
        let slot = CGRect(x: 240, y: 500, width: 110, height: 28)
        let tab = CGSize(width: 220, height: 28)
        let rect = DragShapeMachine.itemRect(.inPlace(strip, slot: slot), pointer: CGPoint(x: 300, y: 470),
                                             grabOffset: CGPoint(x: 110, y: 14), itemSize: tab)
        #expect(rect.minY == 500)
        #expect(rect.height == 28)
        #expect(rect.width == 110)
        // Grabbed at half the tab: the pointer stays at half the slot.
        #expect(rect.midX == 300)
    }

    /// In a sidebar list the row follows the pointer up and down in the
    /// slot's column and width, with the grabbed point under the pointer.
    @Test func verticalInPlaceRectSitsInTheSlotColumn() {
        let slot = CGRect(x: 8, y: 380, width: 224, height: 32)
        let rect = DragShapeMachine.itemRect(.inPlace(sidebar, slot: slot), pointer: CGPoint(x: 150, y: 437),
                                             grabOffset: CGPoint(x: 50, y: 8), itemSize: row)
        #expect(rect.minX == 8)
        #expect(rect.width == 224)
        #expect(rect.height == 32)
        #expect(rect.minY == 429)
    }
}
