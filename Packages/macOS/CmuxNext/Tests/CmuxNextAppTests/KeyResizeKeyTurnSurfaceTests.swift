import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S1B, for S4 (terminals ready-or-keep). In the 120 Hz films the first frame of a key resize
/// shows nothing new: the whole window's commit of the first frame tick after the key misses its display (base and S1
/// builds alike; px-keys-single-3k-s1r frames 240/241, px-keys-held-2-s1r frames 193/416/423/448: 0 changed pixels on
/// every scan line, the next frame on time). The key's own turn is 5-8 ms to its commit (debug.action_budget,
/// resizePane* commit_ms 5.35-8.24 on FEAT DOGFOOD BUILD e0e34bd6, cmux18), and the first press of a film blocks a whole
/// display frame (a 16.7 ms tick gap). The main-thread sample of the held-key film puts that turn's work under
/// `PaneResize.press` -> `syncWithModel` -> `applyPresentation` -> `PaneHostView.announceRest` ->
/// `TerminalSurfaceView.restAt`: each terminal surface takes its rest size in the key's turn (`setFrameSize` ->
/// `updateSurfaceSize` -> `ghostty_surface_set_size`, a reflow on the main thread), beside its final grid to the PTY.
///
/// The rule (S4): the key's turn changes the model and sends each PTY its final grid (one SIGWINCH per press, RESIZE
/// KEYS); it resizes no terminal surface. A surface takes its new size in a frame tick, ready-or-keep, so no input turn
/// holds the frame after it.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyResizeKeyTurnSurfaceTests {
    typealias OneGrid = KeyboardResizeOneGridReportTests

    /// Ctrl-Shift-H, L, K or J on p2: one terminal grows, the other shrinks. In the key's turn no surface takes a new size,
    /// and each PTY gets its final grid; after the landing each surface is at its rest size and sent no other grid.
    @Test(arguments: [LayoutDirection.left, .right, .up, .down])
    func aKeyPressResizesNoTerminalSurfaceInItsOwnTurn(direction: LayoutDirection) async throws {
        let rig = try OneGrid.Rig(direction == .left || direction == .right ? OneGrid.pair : OneGrid.stack)
        defer { rig.close() }
        // The launch's grids (the first layout) are not this press's.
        for pane in rig.panes { _ = try await rig.grids(pane) }
        var logs: [PaneID: OneGrid.SizeLog] = [:]
        for pane in rig.panes { logs[pane] = OneGrid.SizeLog(try rig.terminal(pane).surface) }

        // The key's turn (`PaneResize.press` syncs the layout itself, as the key handler does).
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        var inTurn: [String] = []
        for pane in rig.panes {
            let sizes = try #require(logs[pane]).sizes
            if !sizes.isEmpty { inTurn.append("\(pane.rawValue): \(sizes)") }
        }
        #expect(inTurn.isEmpty, "the key's turn resized terminal surfaces: \(inTurn)")
        var atPress: [PaneID: [TerminalGridSize]] = [:]
        for pane in rig.panes { atPress[pane] = try await rig.grids(pane) }

        // The spring to its landing, and the landing's commit.
        #expect(rig.settle() > 3, "the press did not spring")
        rig.commit()
        for pane in rig.panes {
            let terminal = try rig.terminal(pane)
            let final = try #require(terminal.surface.fittedGrid, "\(pane.rawValue)'s terminal fits no grid")
            #expect(atPress[pane] == [final], "\(pane.rawValue): the key's turn asked the PTY for \(atPress[pane] ?? []), not the final grid \(final)")
            #expect(try await rig.grids(pane).isEmpty, "\(pane.rawValue): the landing asked the PTY for another grid")
            let host = terminal.session.view
            #expect(terminal.surface.frame.size == host.surfaceSize(forHostSize: host.bounds.size),
                    "\(pane.rawValue)'s surface rests at \(terminal.surface.frame.size) in a \(host.bounds.size) host")
        }
    }
}
