import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// CLOSE VARIANTS 4 (the long frame of a close): the key's own turn of a pane close (`PaneController.showPaneClose`).
///
/// The 120 Hz profile (xctrace Time Profiler + os_signpost, cmux24, macOS 27.0, 20 real Cmd-W closes of a split pane's last tab,
/// base 4a16196d) put the long frame in the key's own update cycle (main p50 19.8 ms, p95 25.8 ms). In it the key's turn
/// presented the layout (`syncWithModel` -> `syncScroll` -> `leadIfPending` -> `applyPresentation`: every pane host laid out,
/// each terminal placed, the overlay synced, 2.0 + 0.55 ms), and then, in 20 of 20 closes, the display-link tick ran in the
/// same cycle, before the key's Core Animation commit, and presented the layout again: the key's presentation never showed.
///
/// The rule (Chromium's: input changes the model and asks for a frame; one lifecycle update per frame): a close's key turn
/// changes the model, puts the springs on their targets and asks for a frame. It presents nothing; the first frame tick
/// presents once, and the panes move in it (FRAME OWNER S1B, as a keyboard resize press).
@Suite(.closesItsWindows)
@MainActor struct PaneCloseKeyTurnTests {
    typealias Shown = PaneCloseControllerTests.Shown

    static func drainTurns() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// The right column's only pane closes: its key's turn (and the main turns after it before a display frame) presents
    /// nothing and moves no pane host; the first frame tick presents once and the left column grows into the space.
    @Test func aPaneCloseKeyTurnPresentsNothingUntilItsFirstFrameWhichMovesThePanes() async throws {
        let shown = try Shown([ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(1)), ColumnSnapshot(id: 11, width: 0.5, layout: .leaf(2))])
        defer { shown.end() }
        let root = shown.content.layoutView
        root.context.reduceMotionOverride = false
        root.driver.isManual = true
        root.context.afterCommit = { _ in } // the landing is not part of this test
        try shown.focus(2)
        await Self.drainTurns()
        root.layoutSubtreeIfNeeded()
        let screenID = try #require(shown.content.layoutModel.screens.first?.id)
        let screen = try #require(root.screenViews[screenID])
        let survivor = try #require(root.context.hosts[LayoutPaneID(try shown.key(1))])
        let frame = survivor.frame
        let passes = screen.presentationPasses

        _ = try #require(try shown.controller(2).showPaneClose(), "the right column's only pane waited for the daemon's tree")
        await Self.drainTurns()
        #expect(screen.presentationPasses == passes, "the close's key turn presented the layout \(screen.presentationPasses - passes) times")
        #expect(survivor.frame == frame, "the close's key turn moved the left pane's host: \(survivor.frame) from \(frame)")

        // The first frame tick: one presentation, and the left column grows into the closed pane's space.
        try #require(root.advanceFrame(1.0 / 120), "the close did not spring")
        #expect(screen.presentationPasses == passes + 1, "the first frame presented \(screen.presentationPasses - passes) times, not once")
        #expect(survivor.frame.width > frame.width, "the first frame after the key did not move the left pane: \(survivor.frame) from \(frame)")
    }
}
