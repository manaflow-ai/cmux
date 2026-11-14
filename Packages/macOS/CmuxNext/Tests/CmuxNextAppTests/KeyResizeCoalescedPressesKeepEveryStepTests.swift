import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S1B, #34380's coalescing contract: presses before one frame tick coalesce only their PTY grid
/// report; no press is lost. Each press changes the model in its own turn (`PaneResize.press`), so two Ctrl-Shift-H
/// presses inside one frame move the edge two steps, landing where two presses a frame apart land, and a press and its
/// reverse inside one frame leave the edge where it was and send no grid (Chrome: input coalesces to the frame).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyResizeCoalescedPressesKeepEveryStepTests {
    typealias Ground = PaneGroundCoversPaneTests
    typealias Pin = KeyResizeFirstTickPinTests

    /// p2's left edge (the divider it shares with p1), in window points.
    static func edge(_ rig: Ground.Rig) throws -> CGFloat {
        let host = try #require(rig.root.context.hosts["p2"])
        return host.convert(host.roundedRect, to: nil).minX
    }

    /// Runs frames until nothing moves, then the work after the commit.
    static func land(_ rig: Ground.Rig) {
        var frames = 0
        while frames < 240, rig.frame() { frames += 1 }
        rig.commit()
    }

    /// Two presses inside one frame land where two presses a frame apart land: two steps, not one.
    @Test func twoPressesInsideOneFrameMoveTheEdgeTwoSteps() throws {
        let apart = Ground.Rig(Ground.column(Ground.pair), focused: "p2")
        defer { apart.close() }
        let start = try Self.edge(apart)
        #expect(PaneResize.press("p2", .left, model: apart.model, view: apart.root))
        Self.land(apart)
        let oneStep = try Self.edge(apart)
        #expect(PaneResize.press("p2", .left, model: apart.model, view: apart.root))
        Self.land(apart)
        let twoSteps = try Self.edge(apart)
        #expect(oneStep < start - 1 && twoSteps < oneStep - 1, "the presses a frame apart did not each move the edge: \(start), \(oneStep), \(twoSteps)")

        let together = Ground.Rig(Ground.column(Ground.pair), focused: "p2")
        defer { together.close() }
        #expect(try Self.edge(together) == start)
        #expect(PaneResize.press("p2", .left, model: together.model, view: together.root))
        #expect(PaneResize.press("p2", .left, model: together.model, view: together.root))
        Self.land(together)
        let landed = try Self.edge(together)
        #expect(abs(landed - twoSteps) < 0.5, "two presses inside one frame landed at \(landed), two steps is \(twoSteps), one step \(oneStep): a press was lost")
    }

    /// A press and its reverse inside one frame: the edge stays where it was and no terminal sends a grid.
    @Test func aPressAndItsReverseInsideOneFrameLeaveTheEdge() async throws {
        let rig = Ground.Rig(Ground.column(Ground.pair), focused: "p2")
        defer { rig.close() }
        let panes: [PaneID] = ["p1", "p2"]
        for pane in panes { _ = try await Pin.grids(pane, rig) }
        let start = try Self.edge(rig)
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        #expect(PaneResize.press("p2", .right, model: rig.model, view: rig.root))
        Self.land(rig)
        let landed = try Self.edge(rig)
        #expect(abs(landed - start) < 0.5, "a press and its reverse moved the edge from \(start) to \(landed)")
        for pane in panes {
            #expect(try await Pin.grids(pane, rig).isEmpty, "\(pane.rawValue): a press and its reverse inside one frame sent a grid")
        }
    }
}
