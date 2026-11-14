import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// During a divider drag each terminal's program gets new grids while the divider moves (cmux-ad m29), and after the
/// release's landing its newest grid is its view's. Since RESIZE P0 12 (m55, "terminals: zero lag") a drag's grid goes
/// with the size asked of Ghostty and the presenter holds that size's frame for the program's redraw
/// (`TerminalResizeProgramHoldTests`); before, the grid waited until its size showed, so the program redrew a refresh late.
///
/// S4's rig on a display (`TerminalKeyResizeFrameTests.PaneScreen`, its daemon announcing each grid); a drag of the split's
/// divider 6 pt left per frame for 40 frames, paced 12 ms apart in real time (the coalescer's windows close as in a
/// person's drag), then the release and its landing.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalDragShownGridTests {
    typealias Rig = TerminalKeyResizeFrameTests

    @Test func aDragsProgramFollowsWhileItMovesAndRestsAtItsViewsGrid() async throws {
        let screen = try await Rig.PaneScreen(announcesGrids: true)
        defer { screen.close() }
        await Rig.settle(screen)
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("x")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let before = screen.ios.map { $0.resizes.count }

        view.handleDrag(kind: .split("x"), event: .began(start, []))
        let moves = 40
        for move in 1...moves {
            view.handleDrag(kind: .split("x"), event: .moved(CGPoint(x: start.x - CGFloat(move) * 6, y: start.y), []))
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await Rig.commit()
            try await Task.sleep(for: .milliseconds(12)) // the drag's own pace
        }
        let duringDrag = zip(screen.ios.map { $0.resizes.count }, before).map { $0 - $1 }
        view.handleDrag(kind: .split("x"), event: .ended(CGPoint(x: start.x - CGFloat(moves) * 6, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true, steps = 0
        while moving || steps < 6, steps < 240 {
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the release's frames
            await Rig.commit()
            steps += 1
        }
        await Rig.settle(screen)

        let rested = zip(screen.sessions, screen.ios).map { session, io in
            (fits: session.surfaceView.fittedGrid.map { "\($0.columns)x\($0.rows)" }, newest: io.resizes.last.map { "\($0.columns)x\($0.rows)" })
        }
        print("drag grids: PTY grids during the drag \(duringDrag); rested \(rested)")
        #expect(duringDrag.allSatisfy { $0 >= 2 }, "a program got \(duringDrag) grids while the divider moved: it waits for the landing")
        #expect(rested.allSatisfy { $0.fits == $0.newest }, "after the landing a program's newest grid is not its view's: \(rested)")
    }
}
