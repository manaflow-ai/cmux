import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// Review of #36631 (note 1): during a divider drag a terminal's grid for a size asked of Ghostty waits until that size
/// shows with its frame (`TerminalGridReporter.drag(_:shownNow:)`). When the frame presenter cancels that size instead
/// (the terminal is hidden, or leaves its window, before the frame lands), the grid waited for good: the view had
/// recorded it as reported, so the program kept an older grid until the next resize.
///
/// S4's rig on a display (`TerminalKeyResizeFrameTests.PaneScreen`, its daemon announcing each grid). The split's divider
/// moves left until p1 has a size in flight (its frame not drawn yet); p1's host is hidden in that frame (the presenter
/// cancels the size), and the drag ends at that point. Shown again and settled, p1's program has the grid p1 fits.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalDragCancelledSizeGridTests {
    typealias Rig = TerminalKeyResizeFrameTests

    @Test func aDragGridWhoseSizeThePresenterCancelsStillReachesTheProgram() async throws {
        let screen = try await Rig.PaneScreen(announcesGrids: true)
        defer { screen.close() }
        await Rig.settle(screen)
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("x")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let session = screen.sessions[0], surface = session.surfaceView
        let presenter = TerminalFramePresenter.forWindow(screen.window)

        view.handleDrag(kind: .split("x"), event: .began(start, []))
        var point = start, cancelled = false
        for move in 1...40 where !cancelled {
            point = CGPoint(x: start.x - CGFloat(move) * 6, y: start.y)
            view.handleDrag(kind: .split("x"), event: .moved(point, []))
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            if presenter.isWaiting(surface) {
                // The size waits for its frame: hiding the host now makes the next placement cancel it.
                session.view.isHidden = true
                session.view.needsLayout = true
                session.view.layoutSubtreeIfNeeded() // sync-layout: the hidden host places its surface (the cancel)
                cancelled = !presenter.isWaiting(surface)
            }
            await Rig.commit()
        }
        try #require(cancelled, "p1 never had a size in flight that the presenter then cancelled: the case under test did not happen")
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
        try? await Task.sleep(for: .milliseconds(60)) // a coalesced grid's 25 ms window closes (real clock in this rig)
        await Rig.settle(screen)
        let fits = surface.fittedGrid.map { "\($0.columns)x\($0.rows)" }
        let newest = screen.ios[0].resizes.last.map { "\($0.columns)x\($0.rows)" }
        print("cancelled drag size: p1 fits \(fits ?? "none"), its program's newest grid \(newest ?? "none")")
        #expect(fits == newest, "p1 fits \(fits ?? "none") but its program's newest grid is \(newest ?? "none"): the cancelled size's grid never went")
    }
}
