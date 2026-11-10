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

/// RESIZE P0 12 (Lawrence m55, "terminals: zero lag"): a resize shows a full-screen program's new size only with the
/// frame Ghostty drew after the program's redraw at that size's grid, never with the program's last picture clipped or
/// padded at it, unless the program does not redraw within the hold's bound.
///
/// GI RENDERER SYNC 2 (#40174) port. The rule moved into Ghostty's renderer (`GHOSTTY_HOST_PRESENT_RENDERER_SYNCED`,
/// ghostty-integration.md 4.1), and its unit tests are the fork's (`src/renderer/Metal.zig`, fork c31377f1a): "resize
/// sync: the alternate screen keeps the last frame until the program's redraw or the bound", "resize sync: a grid the PTY
/// owner announced restarts the bound", "resize sync: the primary screen shows a frame of a new host size at once" and
/// "resize sync: no frame is held in the renderer mode, for a first frame, or after a reveal". The present callback has
/// no "program redrew" flag, so these tests check the app's side end to end on a real surface: the surface is in that
/// mode (a quiet program's new size is held, `host_held_frames`, and shows by the bound), a held frame stays top-left and
/// unscaled beside the program's background in a host that clips it, the pane moves at once, every press is held again,
/// and every grid the PTY owner announced reaches Ghostty (its locked grid), which restarts the bound.
///
/// p1 | p2, each a full-screen program (the alternate screen, a ring on its edges) that redraws its ring at each grid
/// its PTY gets, 3 ms after the send (``AnnouncingTerminalIO``), or prints nothing after a resize (a busy program).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalResizeProgramHoldTests {
    /// A held key (Ctrl-Shift-H, H, L on p2 two frames apart, the last to its landing) over programs that redraw: each
    /// frame's new sizes show (at most 2 s each), and at rest each terminal shows its own frame, its PTY has the grid its
    /// view fits and Ghostty has locked that grid (the owner's announcement reached it: the bound restarts there).
    @Test func aKeySpringOverRedrawingProgramsShowsEveryNewSizeAndEndsAtEachViewsGrid() async throws {
        let screen = try await Self.ringScreen()
        defer { screen.close() }
        var steps = 0, stuck = 0
        let presses: [LayoutDirection] = [.left, .left, .right]
        for (index, direction) in presses.enumerated() {
            try #require(PaneResize.press("p2", direction, model: screen.model, view: screen.root), "Ctrl-Shift-\(direction) on p2 moved nothing")
            let last = index == presses.count - 1
            var moving = true, stepped = 0
            while moving, stepped < (last ? 240 : 2) {
                moving = await TerminalKeyResizeFrameTests.stepFrame(screen).moving
                if !(await Self.waitForShownSizes(screen)) { stuck += 1 }
                stepped += 1
            }
            try #require(last || moving, "press \(index + 1) landed before the next press")
            steps += stepped
        }
        try #require(steps >= 4, "the presses' spring ran \(steps) frames: no spring ran")
        #expect(stuck == 0, "\(stuck) of \(steps) frames kept a terminal off its own frame for 2 s")
        try await Self.expectRestsAtItsViewsGrid(screen, "key spring")
    }

    /// The same for a person's divider drag: the split's divider moves 6 pt left per frame for 20 frames, then the
    /// release and its landing.
    @Test func aDividerDragOverRedrawingProgramsShowsEveryNewSizeAndEndsAtEachViewsGrid() async throws {
        let screen = try await Self.ringScreen()
        defer { screen.close() }
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("x")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        var stuck = 0
        view.handleDrag(kind: .split("x"), event: .began(start, []))
        let moves = 20
        for move in 1...moves {
            view.handleDrag(kind: .split("x"), event: .moved(CGPoint(x: start.x - CGFloat(move) * 6, y: start.y), []))
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            if !(await Self.waitForShownSizes(screen)) { stuck += 1 }
        }
        view.handleDrag(kind: .split("x"), event: .ended(CGPoint(x: start.x - CGFloat(moves) * 6, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true, steps = 0
        while moving || steps < 6, steps < 240 {
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the release's frames
            if !(await Self.waitForShownSizes(screen)) { stuck += 1 }
            steps += 1
        }
        #expect(stuck == 0, "\(stuck) drag frames kept a terminal off its own frame for 2 s")
        try await Self.expectRestsAtItsViewsGrid(screen, "divider drag")
    }

    /// Held geometry (RESIZE P0 15, design item 3; m55 lead default) and the bound (RESIZE P0 20), under Reduce Motion
    /// (the press snaps in the key's own turn). p2's program set its background with OSC 11 and does not redraw;
    /// Ctrl-Shift-L grows p2. In the key's commit p2's pane and surface take their new size at once; the host clips its
    /// surface (a held frame larger than its pane never draws over the neighbour), the surface's layer shows its frame
    /// top-left and unscaled, and the strip a grow opens beside the held frame has the program's background colour.
    /// Ghostty holds the new size's frame (`host_held_frames` grows: the surface is in the synced mode) and shows it by
    /// the bound, without the program's redraw.
    @Test func aQuietProgramsNewSizeIsHeldTopLeftBesideItsBackgroundAndShowsByTheBound() async throws {
        let program = RingProgram(redraws: false, background: (0x20, 0x40, 0x60))
        let screen = try await Self.ringScreen(program)
        defer { screen.close() }
        screen.root.context.reduceMotionOverride = true
        let session = screen.sessions[1]
        let view = session.surfaceView
        let host = try #require(view.superview as? TerminalHostView, "SETUP: p2's surface has no host")
        let painted = await TerminalKeyResizeFrameTests.commits(screen, seconds: 2) { _ in session.model.backgroundOverride != nil }
        try #require(painted, "SETUP: p2's OSC 11 set no background")
        #expect(host.layer?.masksToBounds == true, "the host does not clip its surface: a held frame larger than its pane draws over the neighbour")
        #expect(view.layer?.contentsGravity == .topLeft, "p2's surface layer shows its frame with gravity \(String(describing: view.layer?.contentsGravity)), not top-left: a held frame would be stretched or moved")
        let oldHost = host.bounds.size
        let oldFrame = try #require(view.presentedFrame.map { CGSize(width: $0.width, height: $0.height) }, "SETUP: p2 shows no frame")
        let heldBefore = Self.heldFrames(session)

        let pressed = ContinuousClock.now
        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        await TerminalKeyResizeFrameTests.commit() // the key's turn and its commit
        #expect(host.bounds.width > oldHost.width, "p2's pane did not grow in the key's own turn (\(oldHost) -> \(host.bounds.size))")
        #expect(TerminalKeyResizeFrameTests.GridSample(session).onItsArea, "p2's surface is not on its area in the key's commit")
        #expect(Self.sameColor(host.layer?.backgroundColor, program.background),
                "the grow strip is \(String(describing: host.layer?.backgroundColor)), not the program's background")

        // Until the new size shows, the layer keeps the old frame (never a third size); then the bound shows the new one.
        var other: [String] = []
        let shown = await TerminalKeyResizeFrameTests.commits(screen, seconds: 2) { _ in
            if !TerminalKeyResizeFrameTests.showsItsOwnFrame(session), let frame = view.presentedFrame,
               CGSize(width: frame.width, height: frame.height) != oldFrame {
                other.append("\(frame.width)x\(frame.height)")
            }
            return TerminalKeyResizeFrameTests.showsItsOwnFrame(session)
        }
        let ms = TerminalKeyResizeFrameTests.ms(pressed.duration(to: .now))
        print("GI RENDERER SYNC quiet program: new size shown after \(ms) ms, held frames \(Self.heldFrames(session) - heldBefore)")
        #expect(shown, "p2's new size never showed its frame: the bound did not end the hold")
        #expect(other.isEmpty, "p2 showed frames of neither its old nor its new size while held: \(other.prefix(6))")
        #expect(Self.heldFrames(session) > heldBefore, "Ghostty held no frame of p2's new size for its quiet program (host_held_frames): the surface is not in the synced mode")
        // The bound is 3 refreshes of 120 Hz (25 ms); 10 times that leaves room for a loaded host.
        #expect(ms <= 250, "p2's new size showed \(ms) ms after the press: far past the hold's bound")
    }

    /// One bound per size change (RESIZE P0 15, design item 2): a full-screen program that did not redraw within one
    /// press's bound is held again at the next press. Before, a latch turned the hold off for the rest of the session
    /// after one slow redraw. p1 | p2 quiet programs; two presses on p2, each to its landing.
    @Test func aProgramThatMissedOneBoundIsHeldAgainAtTheNextPress() async throws {
        let screen = try await Self.ringScreen(RingProgram(redraws: false))
        defer { screen.close() }
        let session = screen.sessions[1]
        for (press, direction) in [LayoutDirection.left, .right].enumerated() {
            let before = Self.heldFrames(session)
            try #require(PaneResize.press("p2", direction, model: screen.model, view: screen.root), "press \(press + 1) on p2 moved nothing")
            try await Self.stepToLanding(screen)
            await TerminalKeyResizeFrameTests.settle(screen)
            #expect(Self.heldFrames(session) > before, "press \(press + 1): Ghostty held no frame of p2's new size for its quiet program")
            #expect(TerminalKeyResizeFrameTests.showsItsOwnFrame(session), "press \(press + 1): p2 does not rest at its own frame")
        }
    }

    /// Ghostty's frames of `session`'s new sizes not shown because the resize hold ran (`host_held_frames`).
    static func heldFrames(_ session: TerminalSession) -> UInt64 {
        session.surfaceView.surface.map { ghostty_surface_render_counters($0).host_held_frames } ?? 0
    }

    /// At rest (at most 2 s): each terminal shows its own frame, its PTY's last grid is its view's, and Ghostty locked
    /// that grid (the owner's announcement went to `ghostty_surface_set_grid`, which restarts the hold's bound).
    static func expectRestsAtItsViewsGrid(_ screen: TerminalKeyResizeFrameTests.PaneScreen, _ what: String) async throws {
        let rested = await TerminalKeyResizeFrameTests.commits(screen, seconds: 2) { screen in
            screen.sessions.allSatisfy(TerminalKeyResizeFrameTests.showsItsOwnFrame)
                && TerminalKeyResizeFrameTests.ptyEndsAtItsViewsGrid(screen).isEmpty
                && screen.sessions.allSatisfy { $0.drawnAndOwnerGrid.owner == $0.surfaceView.fittedGrid }
        }
        let ends = TerminalKeyResizeFrameTests.ptyEndsAtItsViewsGrid(screen)
        let locks = screen.sessions.enumerated().compactMap { index, session -> String? in
            let owner = session.drawnAndOwnerGrid.owner, fitted = session.surfaceView.fittedGrid
            return owner == fitted ? nil : "p\(index + 1): locked \(TerminalKeyResizeFrameTests.text(owner)), view \(TerminalKeyResizeFrameTests.text(fitted))"
        }
        #expect(rested, "\(what): the terminals did not rest at their own frames and grids in 2 s (PTY \(ends), lock \(locks))")
        #expect(ends.isEmpty, "\(what): a PTY does not end at its view's grid: \(ends)")
        #expect(locks.isEmpty, "\(what): Ghostty did not lock the grid the owner announced: \(locks)")
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

    /// Each frame waits (at most 2 s) for its sizes to show; whether they did.
    @discardableResult
    static func waitForShownSizes(_ screen: TerminalKeyResizeFrameTests.PaneScreen) async -> Bool {
        await TerminalKeyResizeFrameTests.commits(screen, seconds: 2) {
            $0.sessions.allSatisfy(TerminalKeyResizeFrameTests.showsItsOwnFrame)
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
