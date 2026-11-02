import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// RESIZE VIDEOS F1 (STATUS 7221): after #32480 a close still lost a refresh in its first motion frame, and 3 ms of
/// that frame was the closing pane's own strip update taking its parked views out of the window
/// (`PaneController.dropClosedParked` -> `removeFromSuperview`), work no frame shows: the pane is hidden and torn down
/// at the landing anyway. While a pane closes in a spring, its parked views stay until the landing tears it down.
@Suite(.closesItsWindows)
@MainActor struct ClosingPaneKeepsParkedViewsTests {
    private static func drainMain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    @Test(.timeLimit(.minutes(1)))
    func aClosingPanesViewsStayUntilTheLanding() async throws {
        let app = try await ClosedPaneContentStaysUntilLandingTests.Fixture()
        defer { app.close() }
        let closing = try app.pane(2)
        let host = closing.view.contentHost
        let shown = try #require(host.subviews.first { !$0.isHidden }, "fixture: pane 2 shows its terminal's view")
        let prepared = try #require(closing.prepareClose(closing.stripModel.orderedTabs.map(\.id)), "fixture: the close has a daemon tab")
        try #require(app.root.screenViews.values.contains { !$0.isHidden && $0.hasMotion }, "fixture: the close springs")
        // The close's strip updates and presentation, as the app runs them in the motion's frames.
        closing.showSelected()
        closing.syncStripFromStore()
        await Self.drainMain()
        await prepared.finish(false, false)
        var removedInFrame: Int?
        if shown.superview !== host { removedInFrame = 0 }
        var frames = 0
        while frames < 600 {
            let moving = app.root.advanceFrame(ClosedPaneContentStaysUntilLandingTests.dt)
            frames += 1
            closing.syncStripFromStore()
            await Self.drainMain()
            if !moving { break }
            if removedInFrame == nil, shown.superview !== host { removedInFrame = frames }
        }
        #expect(frames > 10, "the close springs over several frames (\(frames))")
        #expect(removedInFrame == nil,
                "the closing pane's view left the window in motion frame \(removedInFrame ?? -1): work no frame shows ran in the motion")
    }
}
