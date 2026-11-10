import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// Review of #36631 (note 1): a terminal hidden during a divider drag, while its newest size has no frame yet, must
/// still give its program the grid it fits. Before, the frame presenter cancelled that size and its grid waited for
/// good: the view had recorded it as reported, so the program kept an older grid until the next resize.
///
/// GI RENDERER SYNC 2 (#40174) port: the presenter is gone (Ghostty times each new size's frame,
/// `GHOSTTY_HOST_PRESENT_RENDERER_SYNCED`), so the case is a size whose frame Ghostty has not shown yet
/// (``TerminalKeyResizeFrameTests/showsItsOwnFrame(_:)`` false) when its host hides.
///
/// S4's rig on a display (`TerminalKeyResizeFrameTests.PaneScreen`, its daemon announcing each grid). The split's divider
/// moves left until p1's newest size has no frame yet; p1's host is hidden in that frame, and the drag ends at that
/// point. Shown again and settled, p1's program has the grid p1 fits. No sleep: it commits until that holds (2 s).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalDragCancelledSizeGridTests {
    typealias Rig = TerminalKeyResizeFrameTests

    @Test func aDragGridOfATerminalHiddenBeforeItsFrameShowsStillReachesTheProgram() async throws {
        let screen = try await Rig.PaneScreen(announcesGrids: true)
        defer { screen.close() }
        await Rig.settle(screen)
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("x")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let session = screen.sessions[0], surface = session.surfaceView

        view.handleDrag(kind: .split("x"), event: .began(start, []))
        var point = start, hidden = false
        for move in 1...40 where !hidden {
            point = CGPoint(x: start.x - CGFloat(move) * 6, y: start.y)
            view.handleDrag(kind: .split("x"), event: .moved(point, []))
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            if !Rig.showsItsOwnFrame(session) {
                // The newest size has no frame yet: the host hides now, before it shows.
                session.view.isHidden = true
                session.view.needsLayout = true
                session.view.layoutSubtreeIfNeeded() // sync-layout: the hidden host places its surface
                hidden = true
            }
            await Rig.commit()
        }
        try #require(hidden, "p1's new size always showed its frame in its own turn: the case under test did not happen")
        view.handleDrag(kind: .split("x"), event: .ended(point, []))
        screen.root.syncWithModel()
        var moving = true, steps = 0
        while moving, steps < 240 {
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the release's frames
            await Rig.commit()
            steps += 1
        }
        session.view.isHidden = false
        await Rig.settle(screen)
        func fits() -> String? { surface.fittedGrid.map { "\($0.columns)x\($0.rows)" } }
        func newest() -> String? { screen.ios[0].resizes.last.map { "\($0.columns)x\($0.rows)" } }
        // A coalesced grid's window ends at a later refresh: commit until the grid went (at most 2 s), no sleep.
        _ = await Rig.commits(screen, seconds: 2) { _ in fits() != nil && fits() == newest() }
        print("hidden drag size: p1 fits \(fits() ?? "none"), its program's newest grid \(newest() ?? "none")")
        #expect(fits() == newest(), "p1 fits \(fits() ?? "none") but its program's newest grid is \(newest() ?? "none"): the hidden size's grid never went")
    }
}
