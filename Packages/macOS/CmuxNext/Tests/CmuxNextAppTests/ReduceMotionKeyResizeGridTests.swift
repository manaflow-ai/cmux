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

/// RESIZE P0 13, KEY SNAP GRID (films px-keys-single-3k-s1r under Reduce Motion, cmux21 1x 120 Hz: a band in the frame
/// that shows the press, 3 of 3 films, the same on v3 = #38125). Under Reduce Motion (or with pane animations off) a
/// keyboard resize press snaps: no spring, so no refresh draws its size ahead (`drawAheadOfKeyPress` returns), and the
/// press presented in the key's own turn. Each terminal took its new size in that turn's commit, before its program
/// had its new grid, so the frame that showed the press showed the program's old picture clipped or padded at the new
/// size (trace keys-single RM: the divider at sample 297, a size-only commit at 298).
///
/// The rule, as for a key spring's first refresh (RESIZE P0 11) and a snapped close (CLOSE MOTION 3): the key's turn
/// gives each resized terminal its new size ahead WITH its grid, and the snap shows at the next frame tick. A close or
/// a zoom snap keeps its rule (its grid goes when it shows, m58: ``ReduceMotionPaneCloseFrameTests``).
///
/// p1 | p2 | p3 (``ReduceMotionPaneCloseFrameTests/ThreePanes``: terminals in the app's pane content, Reduce Motion on,
/// the frames stepped by the test). Ctrl-Shift-L on p2 moves the divider between p2 and p3.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct ReduceMotionKeyResizeGridTests {
    typealias Screen = ReduceMotionPaneCloseFrameTests.ThreePanes

    @Test func aReduceMotionKeyPressSendsEachResizedTerminalsGridBeforeItsNewSizeShows() async throws {
        let screen = try await Screen()
        defer { screen.close() }
        let panes: [PaneID] = ["p1", "p2", "p3"]
        let hosts = try panes.map { try #require(screen.root.context.hosts[$0], "no host for \($0.rawValue)") }
        let frames = hosts.map(\.frame)
        let grids = screen.sessions.map(\.surfaceView.fittedGrid)

        let reports = TerminalSurfaceView.gridReports
        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        await TerminalKeyResizeFrameTests.commit() // the key's turn, its presenter pass and its commit
        let movedInKeyTurn = panes.indices.filter { hosts[$0].frame != frames[$0] }.map { panes[$0].rawValue }
        let keyTurnGrids = TerminalSurfaceView.gridReports - reports

        // The renderer gets the time the app gives it before the next refresh (here: until each size drawn ahead is drawn,
        // at most 1 s), then the first frame tick shows the snap.
        _ = await ReduceMotionPaneCloseFrameTests.commits(screen, seconds: 1) { screen in
            screen.sessions.allSatisfy { session in
                let view = session.surfaceView, state = view.hostFrame(present: false)
                return view.frameOwnership.ahead == nil || state == GHOSTTY_HOST_FRAME_READY || state == GHOSTTY_HOST_FRAME_SHOWN
            }
        }
        _ = screen.root.advanceFrame(1.0 / 120)
        screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
        await TerminalKeyResizeFrameTests.commit()
        let resized = panes.indices.filter { hosts[$0].frame.size != frames[$0].size }
        try #require(!resized.isEmpty, "no pane changed size by the first frame after the press")
        // What the first frame showed, read before the terminals settle: the grids sent by then and each resized
        // terminal's layer in its area.
        let firstFrameGrids = TerminalSurfaceView.gridReports - reports
        let shown = resized.map { index in
            let session = screen.sessions[index], view = session.surfaceView, host = session.view
            return (layer: view.layer?.bounds.size ?? .zero, area: host.surfaceSize(forHostSize: host.bounds.size),
                    scale: view.layer?.contentsScale ?? 2)
        }
        // The press must give some terminal a new grid at rest, or it tests nothing: read where the terminals rest (no
        // size waits for its frame), not at the first frame, which is what the expectations below judge.
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        _ = await ReduceMotionPaneCloseFrameTests.commits(screen, seconds: 1) { screen in
            !screen.sessions.contains { presenter.isWaiting($0.surfaceView) }
        }
        let changedGrid = resized.filter { screen.sessions[$0].surfaceView.fittedGrid != grids[$0] }
        try #require(!changedGrid.isEmpty, """
            no resized terminal rests at a new grid: the press is too small to test (\(resized.map { index in
                "\(panes[index].rawValue): host \(frames[index].size) -> \(hosts[index].frame.size), grid \(String(describing: grids[index])) -> \(String(describing: screen.sessions[index].surfaceView.fittedGrid))"
            }.joined(separator: "; ")))
            """)

        #expect(movedInKeyTurn.isEmpty,
                "the key's turn showed \(movedInKeyTurn) at their new frames before their programs had their grids: a Reduce Motion press shows at the next frame tick")
        #expect(keyTurnGrids == UInt64(changedGrid.count),
                "the key's turn sent \(keyTurnGrids) grids for \(changedGrid.count) terminals with a new grid: each goes with its size drawn ahead, in the key's turn, and only once (a size drawn ahead and then dropped sends the old grid back)")
        #expect(firstFrameGrids == keyTurnGrids,
                "the first frame sent \(firstFrameGrids - keyTurnGrids) more grids after the key's turn")
        for (index, frame) in zip(resized, shown) {
            #expect(abs(frame.layer.width - frame.area.width) * frame.scale <= 1 && abs(frame.layer.height - frame.area.height) * frame.scale <= 1,
                    "the first frame showed \(panes[index].rawValue)'s terminal layer at \(frame.layer) in a \(frame.area) area")
        }
    }

    /// Review of b8085fe5bf1 (P1 1 and 2): a Reduce Motion press taken back by a second press before the frame tick
    /// shows each terminal at its old size, so no placement takes or drops the size drawn ahead for the first press.
    /// The tick shows the held snap through the frame input (`LayoutFrameInput.presentWaiting`), which must release
    /// each size drawn ahead that its placement did not take, as a settle's `presentHeldSnap` does. Before, it skipped
    /// that, and Ghostty and the PTY kept the first press's size and grid until the pane moved again (a scripted resize
    /// burst can do this). Ctrl-Shift-L then Ctrl-Shift-H on p2 in one turn; then frame ticks to rest.
    @Test func aReduceMotionPressTakenBackBeforeTheTickLeavesNoSizeDrawnAhead() async throws {
        try await pressTakenBackLeavesNoSizeDrawnAhead(reduceMotion: true)
    }

    /// Review of b2b71104252 (P1): the same take-back with pane animations on (the default). The first press draws its
    /// first refresh ahead (T-KEYS 3); the second takes it back in the same turn, so the screen has no motion and no held
    /// snap, and no hold begins that could end. The key's turn must release each size drawn ahead that no placement
    /// took. Before, nothing did: Ghostty and the PTY kept the first press's size and grid until the pane moved again.
    @Test func anAnimatedPressTakenBackInItsTurnLeavesNoSizeDrawnAhead() async throws {
        try await pressTakenBackLeavesNoSizeDrawnAhead(reduceMotion: false)
    }

    /// Review of cab3639d25a (P1): the take-back while another pane of the screen still moves. p1 | (p2 | p3), pane
    /// animations on: Ctrl-Shift-L on p2 moves p2 and p3; Ctrl-Shift-L on p1 draws p1's size ahead; Ctrl-Shift-H on p1
    /// takes that back, all in one turn. p1 is at rest, so the last press draws nothing ahead for it and no hold begins
    /// or ends for it; p2 and p3 still move, so the screen has motion. Before, nothing let p1's size go: Ghostty and the
    /// PTY kept the taken-back size and grid until p1 moved again.
    @Test func aPressTakenBackWhileAnotherPaneMovesLeavesNoSizeDrawnAhead() async throws {
        let screen = try await Screen(reduceMotion: false)
        defer { screen.close() }
        let host = try #require(screen.root.context.hosts["p1"], "no host for p1")
        let frame = host.frame
        let view = screen.sessions[0].surfaceView

        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        try #require(PaneResize.press("p1", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p1 moved nothing")
        try #require(view.frameOwnership.pendingAhead != nil || view.frameOwnership.ahead != nil,
                     "SETUP: Ctrl-Shift-L on p1 drew no size ahead for p1's terminal")
        try #require(PaneResize.press("p1", .left, model: screen.model, view: screen.root), "Ctrl-Shift-H on p1 moved nothing")
        await TerminalKeyResizeFrameTests.commit() // the keys' turn, its presenter pass and its commit
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        for _ in 0..<60 {
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await TerminalKeyResizeFrameTests.commit()
        }
        _ = await ReduceMotionPaneCloseFrameTests.commits(screen, seconds: 1) { screen in
            !screen.sessions.contains { presenter.isWaiting($0.surfaceView) }
        }
        try #require(host.frame == frame, "SETUP: Ctrl-Shift-H on p1 did not take the first press back (\(frame) -> \(host.frame))")

        let surface = try #require(view.surface)
        let size = ghostty_surface_size(surface), pixels = view.convertToBacking(view.bounds.size)
        #expect(view.frameOwnership.ahead == nil && view.frameOwnership.pendingAhead == nil,
                "p1 still has the taken-back press's size drawn ahead (ahead \(String(describing: view.frameOwnership.ahead)))")
        #expect(Int(size.width_px) == Int(pixels.width.rounded()) && Int(size.height_px) == Int(pixels.height.rounded()),
                "p1: Ghostty kept \(size.width_px)x\(size.height_px) px for a \(pixels) px view")
        let last = screen.ios[0].resizes.last.map { TerminalGridSize(columns: $0.columns, rows: $0.rows) }
        #expect(last == view.fittedGrid,
                "p1: the PTY kept the grid \(String(describing: last)), the view fits \(String(describing: view.fittedGrid))")
    }

    /// Ctrl-Shift-L then Ctrl-Shift-H on p2 in one turn; then frame ticks to rest: no terminal keeps the first press's
    /// size or grid.
    private func pressTakenBackLeavesNoSizeDrawnAhead(reduceMotion: Bool) async throws {
        let screen = try await Screen(reduceMotion: reduceMotion)
        defer { screen.close() }
        let panes: [PaneID] = ["p1", "p2", "p3"]
        let hosts = try panes.map { try #require(screen.root.context.hosts[$0], "no host for \($0.rawValue)") }
        let frames = hosts.map(\.frame)

        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        let drewAhead = screen.sessions.indices.filter { screen.sessions[$0].surfaceView.frameOwnership.pendingAhead != nil
            || screen.sessions[$0].surfaceView.frameOwnership.ahead != nil }
        try #require(PaneResize.press("p2", .left, model: screen.model, view: screen.root), "Ctrl-Shift-H on p2 moved nothing")
        await TerminalKeyResizeFrameTests.commit() // the keys' turn, its presenter pass and its commit
        try #require(!drewAhead.isEmpty, "SETUP: the first press drew no terminal's size ahead")
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        for _ in 0..<12 {
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await TerminalKeyResizeFrameTests.commit()
        }
        _ = await ReduceMotionPaneCloseFrameTests.commits(screen, seconds: 1) { screen in
            !screen.sessions.contains { presenter.isWaiting($0.surfaceView) }
        }
        try #require(panes.indices.allSatisfy { hosts[$0].frame == frames[$0] },
                     "SETUP: the second press did not take the first back (\(panes.indices.map { "\(frames[$0]) -> \(hosts[$0].frame)" }))")

        for index in drewAhead {
            let session = screen.sessions[index], view = session.surfaceView
            let name = panes[index].rawValue
            let surface = try #require(view.surface)
            let size = ghostty_surface_size(surface), pixels = view.convertToBacking(view.bounds.size)
            #expect(view.frameOwnership.ahead == nil && view.frameOwnership.pendingAhead == nil,
                    "\(name) still has the taken-back press's size drawn ahead (ahead \(String(describing: view.frameOwnership.ahead)))")
            #expect(Int(size.width_px) == Int(pixels.width.rounded()) && Int(size.height_px) == Int(pixels.height.rounded()),
                    "\(name): Ghostty kept \(size.width_px)x\(size.height_px) px for a \(pixels) px view")
            let last = screen.ios[index].resizes.last.map { TerminalGridSize(columns: $0.columns, rows: $0.rows) }
            #expect(last == view.fittedGrid,
                    "\(name): the PTY kept the grid \(String(describing: last)), the view fits \(String(describing: view.fittedGrid))")
        }
    }
}
