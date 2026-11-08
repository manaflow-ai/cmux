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

/// RESIZE P0 12 (Lawrence m55, "terminals: zero lag"): a key resize shows a terminal's new size only with the frame
/// Ghostty drew after the program's redraw at that size's grid, never with the program's last picture clipped or
/// padded at it (a frame of the size only, `GHOSTTY_HOST_FRAME_READY`), unless the program does not redraw within the
/// hold's bound (``TerminalFramePresenter/resizeHoldTicks``).
///
/// Before: the pass presented whatever Ghostty drew for the new size. The grid goes to the program with the size asked
/// of Ghostty (#38125), but the program's output is parsed about 3.5 ms after the send and the pass often came first:
/// cmux21 (macOS 26, 1x 120 Hz) px-keys-held-2-s1r showed the program's old rings cut at the divider in 22-36 frames per
/// film after #38125.
///
/// p1 | p2, each a full-screen program (the alternate screen, a ring on its edges) that redraws its ring at each grid
/// its PTY gets, 3 ms after the send (``AnnouncingTerminalIO``). A held key: Ctrl-Shift-L, L, H on p2 two frames apart,
/// the last to its landing; and a divider drag. Each frame waits (at most 2 s) for its sizes to show.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalResizeProgramHoldTests {
    @Test func aKeySpringShowsEachNewGridOnlyWithTheProgramsRedrawAtIt() async throws {
        let screen = try await Self.ringScreen()
        defer { screen.close() }
        let presents = Presents(screen)
        defer { presents.stop() }

        var steps = 0
        let presses: [LayoutDirection] = [.right, .right, .left]
        for (index, direction) in presses.enumerated() {
            try #require(PaneResize.press("p2", direction, model: screen.model, view: screen.root), "Ctrl-Shift-\(direction) on p2 moved nothing")
            let last = index == presses.count - 1
            var moving = true, stepped = 0
            while moving, stepped < (last ? 240 : 2) {
                moving = await TerminalKeyResizeFrameTests.stepFrame(screen).moving
                await Self.waitForShownSizes(screen)
                stepped += 1
            }
            try #require(last || moving, "press \(index + 1) landed before the next press")
            steps += stepped
        }
        await TerminalKeyResizeFrameTests.settle(screen)
        try #require(steps >= 4, "the presses' spring ran \(steps) frames: no spring ran")
        try presents.check("key spring, \(steps) frames")
    }

    /// The same rule for a person's divider drag (RESIZE P0 12): its grid goes with the size asked of Ghostty, and the size
    /// shows only with the program's redraw at it. Before, the grid went once the size showed (cmux-ad m29), so every drag
    /// frame showed the program's previous picture clipped or padded at the new size. The split's divider moves 6 pt left
    /// per frame for 20 frames, then the release and its landing.
    @Test func aDividerDragShowsEachNewGridOnlyWithTheProgramsRedrawAtIt() async throws {
        let screen = try await Self.ringScreen()
        defer { screen.close() }
        let presents = Presents(screen)
        defer { presents.stop() }
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("x")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)

        view.handleDrag(kind: .split("x"), event: .began(start, []))
        let moves = 20
        for move in 1...moves {
            view.handleDrag(kind: .split("x"), event: .moved(CGPoint(x: start.x - CGFloat(move) * 6, y: start.y), []))
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await Self.waitForShownSizes(screen)
        }
        view.handleDrag(kind: .split("x"), event: .ended(CGPoint(x: start.x - CGFloat(moves) * 6, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true, steps = 0
        while moving || steps < 6, steps < 240 {
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the release's frames
            await Self.waitForShownSizes(screen)
            steps += 1
        }
        await TerminalKeyResizeFrameTests.settle(screen)
        try presents.check("divider drag, \(moves) moves")
    }

    /// p1 | p2, each a full-screen program that draws its ring at its grid and redraws it at each new grid.
    static func ringScreen() async throws -> TerminalKeyResizeFrameTests.PaneScreen {
        let screen = try await TerminalKeyResizeFrameTests.PaneScreen(announcesGrids: true, redraws: Self.ring)
        for (io, session) in zip(screen.ios, screen.sessions) {
            let grid = try #require(session.surfaceView.fittedGrid, "SETUP: a terminal fits no grid")
            io.send(.output(Self.ring(cols: grid.columns, rows: grid.rows)))
        }
        await TerminalKeyResizeFrameTests.settle(screen)
        return screen
    }

    /// Each frame waits (at most 2 s) for its sizes to show.
    static func waitForShownSizes(_ screen: TerminalKeyResizeFrameTests.PaneScreen) async {
        _ = await TerminalKeyResizeFrameTests.commits(screen, seconds: 2) {
            $0.sessions.allSatisfy(TerminalKeyResizeFrameTests.showsItsOwnFrame)
        }
    }

    /// In each pass, just before a frame is presented, what Ghostty says of it: drawn after the program's redraw at its
    /// grid (`READY_PROGRAM`) or of the size only (`READY`).
    @MainActor final class Presents {
        private let presenter: TerminalFramePresenter
        private(set) var program = 0
        private(set) var sizeOnly: [String] = []

        init(_ screen: TerminalKeyResizeFrameTests.PaneScreen) {
            presenter = TerminalFramePresenter.forWindow(screen.window)
            presenter.presentingHook = { [weak self, unowned screen] view, state in
                guard let self else { return }
                let name = screen.sessions.firstIndex { $0.surfaceView === view }.map { "p\($0 + 1)" } ?? "?"
                if state == GHOSTTY_HOST_FRAME_READY_PROGRAM { program += 1 }
                if state == GHOSTTY_HOST_FRAME_READY {
                    let bounds = view.bounds.size, asked = view.frameOwnership.inFlight ?? .zero
                    sizeOnly.append("\(name): \(TerminalKeyResizeFrameTests.text(bounds)) -> \(TerminalKeyResizeFrameTests.text(asked))")
                }
            }
        }

        func stop() { presenter.presentingHook = nil }

        func check(_ what: String) throws {
            print("RESIZE P0 12 hold (\(what)): presents of the program's redraw \(program), of the size only \(sizeOnly.count)")
            try #require(program + sizeOnly.count >= 4, "\(what) presented \(program + sizeOnly.count) new sizes")
            #expect(sizeOnly.isEmpty,
                    "\(what): \(sizeOnly.count) frames showed a new size with the program's last picture, not its redraw at the new grid (3 ms after the send): \(sizeOnly.prefix(8))")
        }
    }

    /// A full-screen program's picture at `cols` x `rows`: the alternate screen, cleared, a ring on its edges.
    nonisolated static func ring(cols: Int, rows: Int) -> Data {
        guard cols >= 2, rows >= 2 else { return Data() }
        let edge = "+" + String(repeating: "-", count: cols - 2) + "+"
        let middle = "|" + String(repeating: " ", count: cols - 2) + "|"
        let lines = [edge] + Array(repeating: middle, count: rows - 2) + [edge]
        return Data(("\u{1B}[?1049h\u{1B}[H\u{1B}[2J" + lines.joined(separator: "\r\n")).utf8)
    }
}
