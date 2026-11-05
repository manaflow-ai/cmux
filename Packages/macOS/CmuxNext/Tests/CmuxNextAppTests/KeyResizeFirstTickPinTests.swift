import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S1B, Codex's review of #34380 at 545841ed267. With a resize press presenting nothing in its own
/// turn, the key hold begins in the press's first frame tick, and that tick can be late (a catch-up after a missed
/// display, up to `FrameScheduler.catchUpLimit`, 0.1 s).
///
/// (a) The held content rides the pane edge that does not move, whatever the first tick's step: the hold's edges were
/// picked from the rest offset of the STEPPED frame against the host's previous size, so a first step past half the
/// travel picked the moving edge (Ctrl-Shift-H on the right pane: the content rode the moving left edge).
/// (b) Presses before one tick coalesce, as input does (Chrome aligns input to the begin-frame): two presses send each
/// terminal one grid, the final one; a press and its reverse send none and resize no surface.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyResizeFirstTickPinTests {
    typealias Ground = PaneGroundCoversPaneTests

    /// The surface of `pane`'s terminal.
    static func surface(_ pane: PaneID, in rig: Ground.Rig) throws -> TerminalSurfaceView {
        try #require(rig.provider.sessions[pane]?.session.surfaceView)
    }

    /// The grids `pane`'s terminal asked its PTY for since the last call.
    static func grids(_ pane: PaneID, _ rig: Ground.Rig) async throws -> [TerminalGridSize] {
        let session = try #require(rig.provider.sessions[pane])
        // cmux-ad m18: a grid in the coalescer's 25 ms window counts as asked for (it goes when the window ends).
        session.session.surfaceView.flushGridReport()
        session.session.surfaceView.bridge.takeUnretainedValue().input.focusGained()
        return await session.io.gridsUntilMarker()
    }

    /// (a) Ctrl-Shift-H on p2 (right of p1): p2 grows to the left and its right edge stays. The first tick is late (0.1 s:
    /// most of the travel in one step). In every frame p2's surface keeps its place against the right edge. With
    /// `motion.frameOwner.terminals` on (cmux-ad m6) the surface fills its area, so it keeps that place because it follows
    /// the pane (cmux-ad m18 deleted the switch-off hold).
    @Test(arguments: [0.1, 1.0 / 120])
    func theHeldSurfaceRidesTheEdgeThatStaysWhenTheFirstTickIsLate(firstStep: Double) throws {
        let rig = Ground.Rig(Ground.column(Ground.pair), focused: "p2")
        defer { rig.close() }
        let host = try #require(rig.root.context.hosts["p2"])
        func rightEdge() -> CGFloat { host.convert(host.roundedRect, to: nil).maxX }
        func surfaceRight() throws -> CGFloat { let s = try Self.surface("p2", in: rig); return s.convert(s.bounds, to: nil).maxX }
        let edge = rightEdge(), inset = try edge - surfaceRight()
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        var off: [String] = [], frames = 0, step = firstStep
        while frames < 240, rig.root.advanceFrame(step) {
            rig.root.layoutSubtreeIfNeeded()
            frames += 1
            step = 1.0 / 120
            if abs(rightEdge() - edge) > 0.5 { off.append("frame \(frames): the right edge moved (\(rightEdge()) from \(edge))") }
            let gap = try rightEdge() - surfaceRight()
            if abs(gap - inset) > 0.5 { off.append("frame \(frames): the surface's right edge is \(gap) from the pane's, \(inset) at rest") }
        }
        #expect(frames > 1, "the press did not spring")
        #expect(off.isEmpty, "\(off.count) frames off the edge that stays: \(off.prefix(3))")
    }

    /// (b) Ctrl-Shift-H twice before one tick: each terminal sends one grid, the final one. Then H and L before one tick:
    /// no terminal sends a grid or takes a new surface size. In both states of `motion.frameOwner.terminals` (review of
    /// #35470, T5).
    @Test
    func pressesBeforeOneTickCoalesce() async throws {
        let rig = Ground.Rig(Ground.column(Ground.pair), focused: "p2")
        defer { rig.close() }
        let panes: [PaneID] = ["p1", "p2"]
        for pane in panes { _ = try await Self.grids(pane, rig) }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        var frames = 0
        while frames < 240, rig.frame() { frames += 1 }
        rig.commit()
        #expect(frames > 3, "the presses did not spring")
        for pane in panes {
            let final = try #require(try Self.surface(pane, in: rig).fittedGrid)
            let grids = try await Self.grids(pane, rig)
            #expect(grids == [final], "\(pane.rawValue): two presses before one tick sent \(grids), not the final grid \(final) once")
        }

        var sizes: [PaneID: CGSize] = [:]
        for pane in panes { sizes[pane] = try Self.surface(pane, in: rig).frame.size }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        #expect(PaneResize.press("p2", .right, model: rig.model, view: rig.root))
        frames = 0
        while frames < 240, rig.frame() { frames += 1 }
        rig.commit()
        for pane in panes {
            #expect(try await Self.grids(pane, rig).isEmpty, "\(pane.rawValue): a press and its reverse before one tick sent a grid")
            #expect(try Self.surface(pane, in: rig).frame.size == sizes[pane], "\(pane.rawValue)'s surface took a new size for a press and its reverse")
        }
    }
}
