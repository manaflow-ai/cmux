import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S2B, a limit of rule D (#35775): a grab holds the line still in the strip, where the layout puts
/// it. The strip's camera is a view offset, not the line's spring: when it starts to move after the press, the held line
/// goes with the strip. A focus change waits for the drag's end to scroll (`reveals: !gestureActive`); a reveal or a
/// center request does not (a tab opened beside a chat, an automation's reveal, Center Column). On screen it moves by the camera's
/// travel, not with the still pointer, until the next pointer event puts it where the pointer says again (the press's
/// drawn place plus the pointer's travel), within the split's limits as for any drag: past a limit the line stays at
/// it. The shared edges stay together all the way (the camera moves every strip frame alike). A press while the camera
/// already moves takes the drag from before S2B (`SharedEdgeCatchFallbackTests`).
@MainActor
@Suite(.closesItsWindows)
struct SharedEdgeCameraLimitTests {
    typealias Rig = SharedEdgeDuringSpringTests.Rig

    @Test func aCameraThatMovesAfterThePressCarriesTheHeldLineWithTheStrip() throws {
        // Four half-width columns: the strip scrolls; the camera rests on A and B.
        let rig = Rig(columns: [
            LayoutColumn(id: "A", width: 0.5, root: .leaf("a")),
            LayoutColumn(id: "B", width: 0.5, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("b1"), b: .leaf("b2"))),
            LayoutColumn(id: "C", width: 0.5, root: .leaf("c")),
            LayoutColumn(id: "E", width: 0.5, root: .leaf("e")),
        ])
        defer { rig.window.closeAfterTest() }
        let edges = try rig.sharedEdges()
        let dividerRest: CGFloat = try #require(rig.dividerOffset(), "no split divider")
        rig.dividerRest = dividerRest
        let screen = try rig.screen
        try #require(!SharedEdgeMotion.viewOffsetMoves(of: .split("x"), axis: .horizontal, on: screen), "the camera moves before the press")
        // B's split on a spring of its own, so the press holds it (rule D).
        try rig.moveLine(by: -6, speed: -40)

        let view = try rig.handle(.split("x")), press = try rig.center(.split("x"))
        let shownBefore = try rig.shownFrames()
        view.mouseDown(with: rig.event(.leftMouseDown, press))
        try rig.expectUnmoved(shownBefore, "the press")
        let keptRuleD = try rig.screen.activeDrag?.sharedEdges
        try #require(keptRuleD == true, "the press did not keep rule D")
        rig.frame(edges, "press frame")
        let start = try rig.edge("b1", \.maxX), cameraAtPress = screen.stripShift
        let pixel = 1 / max(screen.scale, 1) + 0.01

        // A reveal of C during the drag (a tab opened beside a chat): the camera moves, the pointer stays still (no event).
        rig.model.revealColumn(containing: "c")
        rig.root.syncWithModel()
        var frames = 0
        repeat {
            frames += 1
            rig.frame(edges, "camera frame \(frames)")
            // In the strip the line holds still: on screen it moves with the camera only (a pixel of rounding).
            let drift = try rig.edge("b1", \.maxX) - screen.stripShift - (start - cameraAtPress)
            if abs(drift) > pixel { rig.misses.append("camera frame \(frames): the held line moved \(Rig.pt(drift)) pt in the strip") }
        } while SharedEdgeMotion.viewOffsetMoves(of: .split("x"), axis: .horizontal, on: screen) && frames < 240
        let travel = screen.stripShift - cameraAtPress
        try #require(abs(travel) > 20, "the reveal did not move the camera: \(Rig.pt(travel)) pt")
        // The limit: on screen the line went with the camera, away from the still pointer.
        let carried = try rig.edge("b1", \.maxX) - start
        #expect(abs(carried - travel) <= pixel, "the held line moved \(Rig.pt(carried)) pt on screen, the camera \(Rig.pt(travel)) pt")

        // The next pointer event puts the line where the pointer says: the press's drawn place plus the pointer's travel.
        var pointer = press
        pointer.x += travel.rounded() + 10
        view.mouseDragged(with: rig.event(.leftMouseDragged, pointer))
        rig.frame(edges, "pointer frame")
        let shown = try rig.edge("b1", \.maxX), want = start + (pointer.x - press.x), half = try rig.halfPixel
        #expect(abs(shown - want) <= half, "after the camera, the line shows at \(Rig.pt(shown)) pt, the pointer put it at \(Rig.pt(want)) pt")

        view.mouseUp(with: rig.event(.leftMouseUp, pointer))
        rig.root.syncWithModel()
        rig.check(edges, "release")
        rig.land(edges, "landing")
        #expect(rig.misses.isEmpty, "\(rig.misses.count) checks off (first 12):\n\(rig.misses.prefix(12).joined(separator: "\n"))")
    }
}
