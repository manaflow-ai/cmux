import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S2B, rule D's fallback (`DividerDrag.catchShown`): a press that cannot hold while the screen
/// moves takes the drag from before S2B (`DividerDragState.sharedEdges` off: every frame it retargets snaps to its rest
/// place). Cases a real spring does not reach on cue, set up on the springs (#35036 and #35775 reviews):
/// - the strip camera still moves the line in view space (a focus scrolls the strip): stopping the line's own spring
///   cannot hold it where it is drawn;
/// - a clamped press (the whole strip slides by more than a pane's minimum, b1 near its minimum): once the pointer takes
///   the split off the clamp's spring, the split goes where the pointer puts it while b2's far edge still slides, so b2
///   could show a negative width;
/// - a pane whose size spring could carry it further under its rest size than a pane's minimum: b1 shrinks fast (its
///   divider flies toward B's left edge) when B's edge is pressed, and the drag then takes B to its minimum. Rule C
///   keeps each edge's spring through a drag, so b1 would show a negative width.
/// The press moves nothing on screen; the motion then lands with every shared edge in place and no negative size.
@MainActor
@Suite(.closesItsWindows)
struct SharedEdgeCatchFallbackTests {
    typealias Rig = SharedEdgeDuringSpringTests.Rig

    @Test func aPressWhileTheStripCameraMovesTakesTheOldDrag() throws {
        // Four half-width columns, so the strip scrolls; focus on the last one puts the camera on a spring.
        let rig = Rig(columns: [
            LayoutColumn(id: "A", width: 0.5, root: .leaf("a")),
            LayoutColumn(id: "B", width: 0.5, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("b1"), b: .leaf("b2"))),
            LayoutColumn(id: "C", width: 0.5, root: .leaf("c")),
            LayoutColumn(id: "E", width: 0.5, root: .leaf("e")),
        ])
        defer { rig.window.closeAfterTest() }
        rig.model.focus("e", notify: false)
        rig.root.syncWithModel()
        // B's split shows a spring of its own as well (else the press holds nothing), set up on the springs.
        let screen = try rig.screen
        var divider = try #require(screen.dividerFrames[.split("x")])
        (divider.x.value, divider.x.velocity) = (divider.x.value - 6, -40)
        screen.dividerFrames[.split("x")] = divider
        for _ in 0..<3 { _ = rig.root.advanceFrame(1.0 / 120) }
        try #require(abs(screen.scroll.value - screen.scroll.target) > 20, "the camera nearly landed: \(screen.scroll.value) -> \(screen.scroll.target)")
        try #require(SharedEdgeMotion.viewOffsetMoves(of: .split("x"), axis: .horizontal, on: screen), "the strip camera does not move")

        let view = try rig.handle(.split("x")), press = try rig.center(.split("x"))
        view.mouseDown(with: rig.event(.leftMouseDown, press))
        let keptRuleD = try rig.screen.activeDrag?.sharedEdges
        // Stopping the line's own spring cannot hold it where it is drawn while the camera moves it: the old drag.
        #expect(keptRuleD == false, "the press kept rule D while the strip camera still moves the line")
        view.mouseUp(with: rig.event(.leftMouseUp, press))
        rig.root.syncWithModel()
    }

    @Test func aClampedPressWhoseReleaseCouldShowAPaneUnderZeroTakesTheOldDrag() throws {
        // b1 13 pt above its minimum; the whole strip shows 100 pt more than a pane's minimum left of its rest and slides
        // back: from b1's anchor's rest place the split's drawn line leaves b1 far under its minimum, so it clamps.
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let edges = try rig.sharedEdges()
        let minimum = rig.root.context.style.minimumPaneSize.width
        try rig.slideStrip(by: -(minimum + 100), speed: 20)

        let view = try rig.handle(.split("x")), press = try rig.center(.split("x"))
        view.mouseDown(with: rig.event(.leftMouseDown, press))
        let keptRuleD = try rig.screen.activeDrag?.sharedEdges
        #expect(keptRuleD == false, "the press kept rule D though taking the split off its clamp could show b2 under zero")
        // The pointer far right in one move (the split stops at b2's minimum from b2's rest place), then held still.
        var pointer = press
        pointer.x += 600
        view.mouseDragged(with: rig.event(.leftMouseDragged, pointer))
        for tick in 1...12 { rig.frame(edges, "drag frame \(tick)") }
        view.mouseUp(with: rig.event(.leftMouseUp, pointer))
        rig.root.syncWithModel()
        rig.land(edges, "landing")
        // The old drag snaps the split's panes while a and c slide on: their shared edges open, as before S2B. No size
        // may go under zero.
        let negative = rig.misses.filter { $0.contains("negative size") }
        #expect(negative.isEmpty, "\(negative.count) frames show a negative size (first 12):\n\(negative.prefix(12).joined(separator: "\n"))")
    }

    @Test func aPressWhoseDragCouldCarryAPaneUnderZeroBySpeedTakesTheOldDrag() throws {
        // A wide B split in half: b1's own spring keeps it far above zero; only a drag that takes its rest width to its
        // minimum could take it under.
        let rig = Rig(widths: (0.15, 0.7, 0.15), ratio: 0.5)
        defer { rig.window.closeAfterTest() }
        let edges = try rig.sharedEdges()
        let dividerRest: CGFloat = try #require(rig.dividerOffset(), "no split divider")
        rig.dividerRest = dividerRest
        let screen = try rig.screen
        let minimum = rig.root.context.style.minimumPaneSize.width
        let b1 = try #require(screen.paneFrames["b1"]).targetRect.width
        // The speed whose spring path dips 320 pt under its start: further than b1's minimum, less than b1's width
        // (a spring is linear: the dip is in proportion to the speed).
        let spring = Motion.panes.policy.spring(screen.motionState.frameSpring)
        var probe = SpringValue(0)
        probe.velocity = -1000
        var dip: CGFloat = 0
        for _ in 0..<400 {
            probe.step(max(spring.response, 0.05) / 40, parameters: spring)
            dip = min(dip, probe.value)
        }
        try #require(dip < -1, "the panes' spring does not move: dip \(dip) pt")
        let speed = -1000 * 320 / abs(dip)
        try #require(320 > minimum && 320 < b1 - 40, "b1 is \(b1) pt wide, its minimum \(minimum) pt")
        try rig.moveLine(by: -0.5, speed: speed)

        let column = try #require(rig.model.screens.first?.layout.columns.first { $0.id == "B" })
        // B's edge in to B's minimum in one move while b1 still shrinks fast: b2's right edge from b1's left edge.
        try rig.drag(.columnEdge("B"), dragged: "b2", moves: 1, step: -1500, floor: column.minimumSize(style: rig.root.context.style).width,
                     edges: edges) { view, pointer in
            let keptRuleC = try rig.screen.activeDrag?.sharedEdges
            #expect(keptRuleC == false,
                    "the press kept rule C though b1's spring could carry it \(Rig.pt(abs(dip) * abs(speed) / 1000)) pt under its rest width")
            view.mouseUp(with: rig.event(.leftMouseUp, pointer))
            rig.root.syncWithModel()
            rig.check(edges, "release")
        }
        rig.land(edges, "landing")
        #expect(rig.misses.isEmpty, "\(rig.misses.count) checks off (first 12):\n\(rig.misses.prefix(12).joined(separator: "\n"))")
    }
}
