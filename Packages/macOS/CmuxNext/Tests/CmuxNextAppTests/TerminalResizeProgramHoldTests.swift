import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
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

    /// One bound per request (RESIZE P0 15, design item 2): a full-screen program that did not redraw within one press's
    /// bound is held again at the next press. Before, the first bound present set a latch (`programMissedHold`) that only
    /// a frame the program drew for a HELD request cleared, so from then on no size of that terminal waited and every
    /// frame showed the program's last picture clipped or padded (#38206 at 340d74d5967: the hold was off for the rest of
    /// the session after one slow redraw).
    /// p1 | p2 full-screen programs; press 1 (Ctrl-Shift-L on p2) while they print nothing, to its landing (the sizes show
    /// at the bound); then they redraw at each grid again, and press 2 (Ctrl-Shift-H) must show each new grid only with
    /// the program's redraw at it.
    @Test func aProgramThatMissedOneBoundIsHeldAgainAtTheNextPress() async throws {
        let program = RingProgram(redraws: false)
        let screen = try await Self.ringScreen(program)
        defer { screen.close() }
        let presenter = TerminalFramePresenter.forWindow(screen.window)

        let before = presenter.stats.boundPresents
        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        try await Self.stepToLanding(screen)
        await TerminalKeyResizeFrameTests.settle(screen)
        try #require(presenter.stats.boundPresents > before,
                     "SETUP: press 1 showed no size at the hold's bound (bound presents \(before) -> \(presenter.stats.boundPresents)): the quiet program was not held")

        // The program is slow, not dead: as a real one does after its SIGWINCH, it redraws late, once, at its newest grid.
        // Without this its picture would stay at the grid before press 1, and press 2's first refresh (a 2 px step at
        // the same grid, so no new grid to answer) would show that stale picture whatever the hold does.
        program.redraws = true
        for (io, session) in zip(screen.ios, screen.sessions) {
            let grid = try #require(session.surfaceView.fittedGrid, "SETUP: a terminal fits no grid")
            io.send(.output(program.redraw(cols: grid.columns, rows: grid.rows)))
        }
        await TerminalKeyResizeFrameTests.settle(screen)
        let presents = Presents(screen)
        defer { presents.stop() }
        try #require(PaneResize.press("p2", .left, model: screen.model, view: screen.root), "Ctrl-Shift-H on p2 moved nothing")
        try await Self.stepToLanding(screen)
        await TerminalKeyResizeFrameTests.settle(screen)
        try presents.check("the press after a missed bound")
    }

    /// Held geometry (RESIZE P0 15, design item 3; m55 lead default): while a full-screen program's redraw is due, the
    /// pane moves in the press's first frame and the surface keeps the program's last frame at its OLD size, anchored
    /// top-left in the pane, unscaled (its layer shows its frame pixel for pixel); the strip a grow opens beside it has the
    /// program's background colour (OSC 11), not the theme's. The host clips the old frame at its own edge on a shrink,
    /// so it never draws over the neighbour. p2's program set its background with OSC 11 and does not redraw; Ctrl-Shift-H
    /// grows p2.
    @Test func aHeldFrameKeepsItsOldSizeTopLeftBesideTheProgramsBackground() async throws {
        let program = RingProgram(redraws: false, background: (0x20, 0x40, 0x60))
        let screen = try await Self.ringScreen(program)
        defer { screen.close() }
        let session = screen.sessions[1]
        let view = session.surfaceView
        let host = try #require(view.superview as? TerminalHostView, "SETUP: p2's surface has no host")
        let painted = await TerminalKeyResizeFrameTests.commits(screen, seconds: 2) { _ in session.model.backgroundOverride != nil }
        try #require(painted, "SETUP: p2's OSC 11 set no background")
        try #require(host.layer?.masksToBounds == true, "the host does not clip its surface: a held frame larger than its pane draws over the neighbour")
        let oldSize = view.bounds.size, oldHost = host.bounds.size

        try #require(PaneResize.press("p2", .left, model: screen.model, view: screen.root), "Ctrl-Shift-H on p2 moved nothing")
        var held: [String] = [], checked = 0
        var moving = true, steps = 0
        while moving, steps < 240 {
            moving = await TerminalKeyResizeFrameTests.stepFrame(screen).moving
            steps += 1
            guard view.frameOwnership.inFlight != nil, let wanted = view.frameOwnership.wanted, wanted.width > view.frame.width
            else { continue }
            checked += 1
            let frame = view.frame
            if frame.minX != wanted.minX || frame.maxY != wanted.maxY { held.append("frame \(steps): \(frame) not top-left in \(wanted)") }
            if let layer = view.layer, let shown = view.presentedFrame {
                let scale = layer.contentsScale
                if Int((layer.bounds.width * scale).rounded()) != shown.width || Int((layer.bounds.height * scale).rounded()) != shown.height {
                    held.append("frame \(steps): layer \(layer.bounds.size) scales a \(shown.width)x\(shown.height) frame")
                }
            }
            if host.bounds.size == oldHost { held.append("frame \(steps): the pane waited with the surface (host \(oldHost))") }
            if !Self.sameColor(host.layer?.backgroundColor, program.background) {
                held.append("frame \(steps): the grow strip is \(String(describing: host.layer?.backgroundColor)), not the program's background")
            }
        }
        await TerminalKeyResizeFrameTests.settle(screen)
        try #require(steps >= 4, "the press's spring ran \(steps) frames: no spring ran")
        try #require(checked >= 1, "no frame held p2 at its old size \(oldSize) while its pane grew (the quiet program was not held)")
        #expect(held.isEmpty, "\(held.count) held frames broke the held geometry: \(held.prefix(6))")
    }

    /// Whether `color` is the sRGB colour `rgb` (to 1/255), opaque.
    static func sameColor(_ color: CGColor?, _ rgb: (UInt8, UInt8, UInt8)?) -> Bool {
        guard let rgb, let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB), srgb.alphaComponent == 1 else { return false }
        let parts = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return parts == [Int(rgb.0), Int(rgb.1), Int(rgb.2)]
    }

    /// Steps a key press's spring to its landing, each frame waiting (at most 2 s) for its sizes to show.
    static func stepToLanding(_ screen: TerminalKeyResizeFrameTests.PaneScreen) async throws {
        var moving = true, steps = 0
        while moving, steps < 240 {
            moving = await TerminalKeyResizeFrameTests.stepFrame(screen).moving
            await Self.waitForShownSizes(screen)
            steps += 1
        }
        try #require(steps >= 2, "the press's spring ran \(steps) frames: no spring ran")
    }

    /// A full-screen program whose redraw at each new grid can be turned off (it then prints nothing after a resize, as a
    /// program busy at the moment of SIGWINCH), and that can set its background colour with OSC 11.
    nonisolated final class RingProgram: Sendable {
        private let state: Mutex<Bool>
        let background: (UInt8, UInt8, UInt8)?

        init(redraws: Bool, background: (UInt8, UInt8, UInt8)? = nil) {
            state = Mutex(redraws)
            self.background = background
        }

        var redraws: Bool {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }

        /// The first picture: the background (OSC 11) and the ring.
        func first(cols: Int, rows: Int) -> Data {
            let osc = background.map { String(format: "\u{1B}]11;rgb:%02x/%02x/%02x\u{1B}\\", $0.0, $0.1, $0.2) } ?? ""
            return Data(osc.utf8) + TerminalResizeProgramHoldTests.ring(cols: cols, rows: rows)
        }

        /// The answer to a new grid: the ring at it, or nothing.
        func redraw(cols: Int, rows: Int) -> Data {
            redraws ? TerminalResizeProgramHoldTests.ring(cols: cols, rows: rows) : Data()
        }
    }

    /// p1 | p2, each a full-screen program that draws its ring at its grid and redraws it at each new grid.
    static func ringScreen() async throws -> TerminalKeyResizeFrameTests.PaneScreen {
        try await ringScreen(RingProgram(redraws: true))
    }

    /// p1 | p2, each running `program`.
    static func ringScreen(_ program: RingProgram) async throws -> TerminalKeyResizeFrameTests.PaneScreen {
        let screen = try await TerminalKeyResizeFrameTests.PaneScreen(announcesGrids: true) { [program] cols, rows in
            program.redraw(cols: cols, rows: rows)
        }
        for (io, session) in zip(screen.ios, screen.sessions) {
            let grid = try #require(session.surfaceView.fittedGrid, "SETUP: a terminal fits no grid")
            io.send(.output(program.first(cols: grid.columns, rows: grid.rows)))
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
