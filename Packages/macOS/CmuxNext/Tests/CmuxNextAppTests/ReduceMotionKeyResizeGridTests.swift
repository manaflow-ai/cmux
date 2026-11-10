import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Foundation
import GhosttyNextKit
import Testing

/// RESIZE P0 13, KEY SNAP GRID (films px-keys-single-3k-s1r under Reduce Motion, cmux21 1x 120 Hz). Under Reduce Motion
/// (or with pane animations off) a keyboard resize press snaps: no spring. Each resized terminal must end at its pane's
/// size with its program at the grid that size fits, and a press taken back must leave no terminal (Ghostty or its
/// PTY) at the taken-back size.
///
/// GI RENDERER SYNC 2 (#40174) port. The draw-ahead and the snap's wait for the next frame tick are gone: the press shows
/// in the key's own turn (``KeyResizeReduceMotionKeyTurnTests``), and Ghostty times each terminal's new-size frame
/// (`GHOSTTY_HOST_PRESENT_RENDERER_SYNCED`: a full-screen program's last frame stays top-left until its redraw at the
/// new grid or the bound, fork test "resize sync: the alternate screen keeps the last frame until the program's redraw
/// or the bound", `src/renderer/Metal.zig`). What stays the app's is here: the surface takes its pane's area in the
/// key's commit, one grid per resized terminal, and nothing kept at a taken-back size.
///
/// p1 | p2 | p3 (``ReduceMotionPaneCloseFrameTests/ThreePanes``: terminals in the app's pane content, Reduce Motion on,
/// the frames stepped by the test). Ctrl-Shift-L on p2 moves the divider between p2 and p3.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct ReduceMotionKeyResizeGridTests {
    typealias Screen = ReduceMotionPaneCloseFrameTests.ThreePanes

    @Test func aReduceMotionKeyPressShowsEachResizedTerminalAtItsPanesSizeInTheKeysCommitWithOneGrid() async throws {
        let screen = try await Screen()
        defer { screen.close() }
        let panes: [PaneID] = ["p1", "p2", "p3"]
        let hosts = try panes.map { try #require(screen.root.context.hosts[$0], "no host for \($0.rawValue)") }
        let frames = hosts.map(\.frame)
        let grids = screen.sessions.map(\.surfaceView.fittedGrid)

        let gridsBefore = screen.ios.map { $0.resizes.count }
        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        await TerminalKeyResizeFrameTests.commit() // the key's turn and its commit
        let resized = panes.indices.filter { hosts[$0].frame.size != frames[$0].size }
        try #require(!resized.isEmpty, "no pane changed size in the key's own turn: the Reduce Motion press waited")
        // What the key's commit showed: each resized terminal's layer in its area.
        let shown = resized.map { index in
            let session = screen.sessions[index], view = session.surfaceView, host = session.view
            return (layer: view.layer?.bounds.size ?? .zero, area: host.surfaceSize(forHostSize: host.bounds.size),
                    scale: view.layer?.contentsScale ?? 2)
        }
        _ = screen.root.advanceFrame(1.0 / 120)
        screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
        await TerminalKeyResizeFrameTests.commit()
        // Where the terminals rest (each shows its own frame and its PTY has a grid its view fits, at most 2 s): the press
        // must give some terminal a new grid.
        _ = await ReduceMotionPaneCloseFrameTests.commits(screen, seconds: 2) { screen in
            screen.sessions.allSatisfy(TerminalKeyResizeFrameTests.showsItsOwnFrame) && resized.allSatisfy { index in
                screen.ios[index].resizes.last.map { TerminalGridSize(columns: $0.columns, rows: $0.rows) } == screen.sessions[index].surfaceView.fittedGrid
            }
        }
        let changedGrid = resized.filter { screen.sessions[$0].surfaceView.fittedGrid != grids[$0] }
        try #require(!changedGrid.isEmpty, "no resized terminal rests at a new grid: the press is too small to test")

        for (index, frame) in zip(resized, shown) {
            #expect(abs(frame.layer.width - frame.area.width) * frame.scale <= 1 && abs(frame.layer.height - frame.area.height) * frame.scale <= 1,
                    "the key's commit showed \(panes[index].rawValue)'s terminal layer at \(frame.layer) in a \(frame.area) area")
        }
        // One grid per terminal with a new grid, counted at this screen's own PTYs. `TerminalSurfaceView.gridReports`
        // counts every terminal of the process, and the terminals of the suites that run beside this one report in the
        // awaits above (red at 35f0e356de2d beside 10 other suites: 6 reports counted; green alone). A grid reaches its
        // IO through the ordered input stream, so the count is read after a marker that goes through that stream behind
        // every grid asked for so far: it is every grid of the press, the first frame's included, also one more that
        // follows the final grid.
        let reached = await ReduceMotionPaneCloseFrameTests.gridsReachedTheirPTYs(screen, Array(screen.ios.indices))
        try #require(reached, "a terminal's input stream did not reach its PTY in 2 s")
        let sent = zip(screen.ios, gridsBefore).map { $0.resizes.count - $1 }
        #expect(sent.reduce(0, +) <= changedGrid.count,
                "the press sent \(sent) grids to p1, p2, p3 for \(changedGrid.count) terminals with a new grid: one each")
        for index in resized {
            let view = screen.sessions[index].surfaceView
            let last = screen.ios[index].resizes.last.map { TerminalGridSize(columns: $0.columns, rows: $0.rows) }
            #expect(last == view.fittedGrid,
                    "\(panes[index].rawValue): the PTY has the grid \(String(describing: last)), the view fits \(String(describing: view.fittedGrid))")
        }
    }

    /// Review of b8085fe5bf1 (P1 1 and 2): a Reduce Motion press taken back by a second press in the same turn leaves no
    /// terminal at the first press's size: Ghostty's pixel size is its view's and its PTY's grid is the one its view fits.
    /// Before, Ghostty and the PTY kept the first press's size and grid until the pane moved again (a scripted resize burst
    /// can do this). Ctrl-Shift-L then Ctrl-Shift-H on p2 in one turn; then frame ticks to rest.
    @Test func aReduceMotionPressTakenBackInItsTurnLeavesNoTerminalAtItsSize() async throws {
        try await pressTakenBackLeavesNoTerminalAtItsSize(reduceMotion: true)
    }

    /// Review of b2b71104252 (P1): the same take-back with pane animations on (the default): the screen has no motion
    /// after the second press, and no terminal keeps the first press's size or grid.
    @Test func anAnimatedPressTakenBackInItsTurnLeavesNoTerminalAtItsSize() async throws {
        try await pressTakenBackLeavesNoTerminalAtItsSize(reduceMotion: false)
    }

    /// Review of cab3639d25a (P1): the take-back while another pane of the screen still moves. p1 | (p2 | p3), pane
    /// animations on: Ctrl-Shift-L on p2 moves p2 and p3; Ctrl-Shift-L then Ctrl-Shift-H on p1, all in one turn. p1 is
    /// back at rest while p2 and p3 still move. p1 must not keep the taken-back size or grid.
    @Test func aPressTakenBackWhileAnotherPaneMovesLeavesNoTerminalAtItsSize() async throws {
        let screen = try await Screen(reduceMotion: false)
        defer { screen.close() }
        let host = try #require(screen.root.context.hosts["p1"], "no host for p1")
        let frame = host.frame
        let view = screen.sessions[0].surfaceView

        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        try #require(PaneResize.press("p1", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p1 moved nothing")
        try #require(PaneResize.press("p1", .left, model: screen.model, view: screen.root), "Ctrl-Shift-H on p1 moved nothing")
        await TerminalKeyResizeFrameTests.commit() // the keys' turn and its commit
        for _ in 0..<60 {
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await TerminalKeyResizeFrameTests.commit()
        }
        _ = await ReduceMotionPaneCloseFrameTests.commits(screen, seconds: 2, until: Self.rests)
        try #require(host.frame == frame, "SETUP: Ctrl-Shift-H on p1 did not take the first press back (\(frame) -> \(host.frame))")
        try Self.expectAtItsViewsSize(screen, index: 0, name: "p1")
    }

    /// Ctrl-Shift-L then Ctrl-Shift-H on p2 in one turn; then frame ticks to rest: no terminal keeps the first press's
    /// size or grid.
    private func pressTakenBackLeavesNoTerminalAtItsSize(reduceMotion: Bool) async throws {
        let screen = try await Screen(reduceMotion: reduceMotion)
        defer { screen.close() }
        let panes: [PaneID] = ["p1", "p2", "p3"]
        let hosts = try panes.map { try #require(screen.root.context.hosts[$0], "no host for \($0.rawValue)") }
        let frames = hosts.map(\.frame)

        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        try #require(PaneResize.press("p2", .left, model: screen.model, view: screen.root), "Ctrl-Shift-H on p2 moved nothing")
        await TerminalKeyResizeFrameTests.commit() // the keys' turn and its commit
        for _ in 0..<12 {
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await TerminalKeyResizeFrameTests.commit()
        }
        _ = await ReduceMotionPaneCloseFrameTests.commits(screen, seconds: 2, until: Self.rests)
        try #require(panes.indices.allSatisfy { hosts[$0].frame == frames[$0] },
                     "SETUP: the second press did not take the first back (\(panes.indices.map { "\(frames[$0]) -> \(hosts[$0].frame)" }))")
        for index in panes.indices { try Self.expectAtItsViewsSize(screen, index: index, name: panes[index].rawValue) }
    }

    /// Every terminal shows its own frame, and each PTY that got a grid has the one its view fits.
    static func rests(_ screen: Screen) -> Bool {
        screen.sessions.indices.allSatisfy { index in
            let session = screen.sessions[index]
            guard TerminalKeyResizeFrameTests.showsItsOwnFrame(session) else { return false }
            guard let last = screen.ios[index].resizes.last else { return true }
            return TerminalGridSize(columns: last.columns, rows: last.rows) == session.surfaceView.fittedGrid
        }
    }

    /// Terminal `index`: Ghostty's pixel size is its view's, and its PTY's last grid (if it got one) is the one its view fits.
    static func expectAtItsViewsSize(_ screen: Screen, index: Int, name: String) throws {
        let view = screen.sessions[index].surfaceView
        let surface = try #require(view.surface)
        let size = ghostty_surface_size(surface), pixels = view.convertToBacking(view.bounds.size)
        #expect(Int(size.width_px) == Int(pixels.width.rounded()) && Int(size.height_px) == Int(pixels.height.rounded()),
                "\(name): Ghostty kept \(size.width_px)x\(size.height_px) px for a \(pixels) px view")
        guard let last = screen.ios[index].resizes.last.map({ TerminalGridSize(columns: $0.columns, rows: $0.rows) }) else { return }
        #expect(last == view.fittedGrid, "\(name): the PTY kept the grid \(last), the view fits \(String(describing: view.fittedGrid))")
    }
}
