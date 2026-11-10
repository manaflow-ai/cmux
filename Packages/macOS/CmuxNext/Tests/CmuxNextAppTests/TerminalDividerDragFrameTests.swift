import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// cmux-ad m14 (Lawrence's P0, "resizing splits/columns, still not animating the terminals"): in every frame of a
/// divider drag each terminal shows live pixels at that frame's pane size, not frozen, not stretched, not anchored; its
/// program (the PTY) still gets one grid, when the drag lands. Before: the drag hold (`terminalDrag.holdSurface`, RESIZE
/// VIDEOS A3) kept each surface at its drag-start size for the whole drag and its release (pixel-perfect's trace,
/// STATUS 13764: col-drag-2 held 157-159 ticks per film, the surface up to 150 pt off its pane). Now each drag frame gives
/// the surface its pane's size through the placement every resize uses: the frame owner shows each size with its frame
/// drawn at it (or keeps the last frame and size, top-left, until it is drawn); cmux-ad m26 (T-KEYS) deleted the switch
/// `motion.frameOwner.terminals` and its off path.
///
/// S4's rig (`TerminalKeyResizeFrameTests.PaneScreen`: p1 | p2, the app's pane content with a terminal in each, a window
/// on screen); a drag of the split's divider 6 pt left per frame for 20 frames, then the release and its landing. After
/// each frame's commit, per terminal, in the committed layer tree: its top-left on its area's, a size its pane had in this
/// drag (this frame or an earlier one), the frame shown at the layer's pixel size; after the landing, at its final size,
/// its PTY's newest grid the one it fits; and each terminal took a new size in at least half of the drag frames (it
/// follows its pane; the drag hold gave 0).
///
/// GI RENDERER SYNC 2 (#40174) port. The frame owner is gone: the layer takes its pane's area in each drag frame, and
/// Ghostty shows the frame of that size when it is drawn (a frame of a new size goes through the main queue). So a
/// terminal that is behind its pane now has a layer of the area's size with the frame of an earlier drag frame in it,
/// drawn 1:1 from the top-left (cut, or the pane's ground at its right and bottom): the same picture as before, when
/// the layer kept that earlier size. The checks read the SHOWN FRAME: its pixel size is a size its pane had in this drag
/// (this frame or an earlier one), it is never scaled to its layer (``TerminalKeyResizeFrameTests/Sample/drawnUnscaled``),
/// and it took a new size in at least half of the drag frames. "The frame shown at the layer's pixel size" was red at
/// d703d217459e (aws-m4pro-3: 5 of 42 samples showed the frame of one drag frame earlier) and is no longer the rule;
/// those samples are "frames behind their pane": at most 1 frame of 4 per terminal (this port's choice, not a
/// measured limit: aws-m4pro-3 gave 1 of 21 at 3be5828e3a33).
///
/// It needs a window on a display (a display worker: `cmux-ci run --display --label gui-session-v1`).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalDividerDragFrameTests {
    typealias Rig = TerminalKeyResizeFrameTests
    typealias Sample = TerminalKeyResizeFrameTests.Sample

    @Test
    func aDividerDragShowsEachTerminalAtItsPanesSizeInEveryFrameAndResizesItsProgramOnce() async throws {
        let screen = try await Rig.PaneScreen()
        defer { screen.close() }
        await Rig.settle(screen)
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("x")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let resizesBefore = screen.ios.map { $0.resizes.count }
        let before = screen.sessions.map(Sample.init)
        var frames: [[Sample]] = [before]

        view.handleDrag(kind: .split("x"), event: .began(start, []))
        let moves = 20
        for move in 1...moves {
            view.handleDrag(kind: .split("x"), event: .moved(CGPoint(x: start.x - CGFloat(move) * 6, y: start.y), []))
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            // One move per display refresh, as a person's drag arrives (RESIZE P0 14): 20 moves in one commit each took
            // about 12 ms, less than the 3 refreshes a new size may wait for its program's redraw.
            await Rig.refreshOfTime()
            frames.append(screen.sessions.map(Sample.init))
        }
        let dragFrames = frames.count
        view.handleDrag(kind: .split("x"), event: .ended(CGPoint(x: start.x - CGFloat(moves) * 6, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true, steps = 0
        while moving, steps < 240 {
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the landing's frames, as the frame tick runs them
            await Rig.commit()
            frames.append(screen.sessions.map(Sample.init))
            steps += 1
        }
        try #require(frames.contains { $0.map(\.area) != before.map(\.area) }, "the drag changed no pane's area")

        var misplaced: [String] = [], unsized: [String] = [], stretched: [String] = []
        // Frames in which a terminal showed a frame of another size than its pane's area (a size waits a frame or more
        // for its frame to be drawn): reported for the PR's numbers, not asserted.
        var behind = Array(repeating: 0, count: before.count)
        var changes = Array(repeating: 0, count: before.count)
        var frameless: [String] = []
        for index in 1..<frames.count {
            for (terminal, sample) in frames[index].enumerated() {
                let scale = sample.scale
                func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) * scale <= 1 }
                if index < dragFrames, sample.shownPixels != frames[index - 1][terminal].shownPixels { changes[terminal] += 1 }
                if !near(sample.topLeft.x, sample.areaTopLeft.x) || !near(sample.topLeft.y, sample.areaTopLeft.y) {
                    misplaced.append("frame \(index) p\(terminal + 1): top-left \(sample.topLeft), its area's \(sample.areaTopLeft)")
                }
                let had = frames[0...index].map { $0[terminal].area }
                if !had.contains(where: { near(sample.layer.width, $0.width) && near(sample.layer.height, $0.height) }) {
                    unsized.append("frame \(index) p\(terminal + 1): layer \(Rig.text(sample.layer)), area \(Rig.text(sample.area))")
                }
                guard let shown = sample.shownPixels else {
                    frameless.append("frame \(index) p\(terminal + 1)")
                    continue
                }
                // The frame's own size: a size the pane had so far (in device px), never one of a later frame.
                if !had.contains(where: { abs($0.width * scale - shown.width) <= 1 && abs($0.height * scale - shown.height) <= 1 }) {
                    unsized.append("frame \(index) p\(terminal + 1): frame \(Rig.text(shown)) px, area \(Rig.text(sample.area)) at \(scale)x")
                }
                if abs(sample.area.width * scale - shown.width) > 1 || abs(sample.area.height * scale - shown.height) > 1 { behind[terminal] += 1 }
                // A frame of another size than its layer is drawn 1:1 from the top-left, or it is stretched.
                if abs(sample.layer.width * scale - shown.width) > 1 || abs(sample.layer.height * scale - shown.height) > 1, !sample.drawnUnscaled {
                    stretched.append("frame \(index) p\(terminal + 1): layer \(Rig.text(sample.layer)) at \(scale)x, frame \(Rig.text(shown)) px, gravity \(sample.gravity.rawValue)")
                }
            }
        }
        await Rig.settle(screen)
        let rested = screen.sessions.map(Sample.init)
        let landed = rested.enumerated().filter { _, sample in
            abs(sample.layer.width - sample.area.width) * sample.scale > 1 || abs(sample.layer.height - sample.area.height) * sample.scale > 1
        }.map { "p\($0.offset + 1): layer \(Rig.text($0.element.layer)), area \(Rig.text($0.element.area))" }
        let resizes = zip(screen.ios.map { $0.resizes.count }, resizesBefore).map { $0 - $1 }
        let grids = zip(screen.sessions, screen.ios).map { session, io in
            (fits: session.surfaceView.fittedGrid.map { "\($0.columns)x\($0.rows)" }, newest: io.resizes.last.map { "\($0.columns)x\($0.rows)" })
        }
        print("m14 drag: \(moves) drag frames, \(steps) landing frames; frames of a new size in drag frames \(changes); " +
              "frames behind their pane \(behind) of \(frames.count - 1); PTY grids \(resizes); misplaced \(misplaced.count), " +
              "unsized \(unsized.count), stretched \(stretched.count), no frame \(frameless.count)")
        #expect(changes.allSatisfy { $0 >= moves / 2 }, "a terminal showed a frame of a new size in only \(changes) of \(moves) drag frames: the drag holds it")
        #expect(behind.allSatisfy { $0 * 4 <= frames.count - 1 },
                "a terminal showed the frame of an earlier size than its pane's in \(behind) of \(frames.count - 1) frames: it is behind its pane")
        #expect(misplaced.isEmpty, "\(misplaced.count) frames showed a terminal off its pane's top-left: \(misplaced.prefix(8))")
        #expect(unsized.isEmpty, "\(unsized.count) frames showed a terminal at a size its pane had not had yet: \(unsized.prefix(8))")
        #expect(stretched.isEmpty, "\(stretched.count) frames showed a terminal's frame scaled to a layer of another pixel size: \(stretched.prefix(8))")
        #expect(frameless.isEmpty, "\(frameless.count) frames showed a terminal with no frame: \(frameless.prefix(8))")
        #expect(landed.isEmpty, "after the landing a terminal does not show its pane's size: \(landed)")
        #expect(grids.allSatisfy { $0.fits == $0.newest }, "after the landing a PTY's newest grid is not the one its view fits: \(grids)")
    }
}
