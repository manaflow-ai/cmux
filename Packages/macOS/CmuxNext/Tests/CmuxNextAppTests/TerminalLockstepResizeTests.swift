import AppKit
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// Lockstep resize (Leo, 2026-11-24: "it lags, it doesn't follow in lockstep. i want all our resizing at any cpu to be
/// able to happen in lockstep"): in a person's resize gesture a terminal's bounds take its pane's frame in the layout pass
/// that moves the divider, whether or not Ghostty drew the new size; outside a gesture they still wait for their frame.
/// Under load (load average 150) the kept frame held the terminal's edge several refreshes behind the divider.
///
/// A real Ghostty surface in a window (``TerminalSurfaceCommitSizeTests/Fixture``); each layout runs in the test's own
/// turn, so its result is read before any pass or Ghostty frame could land it.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)))
struct TerminalLockstepResizeTests {
    typealias Fixture = TerminalSurfaceCommitSizeTests.Fixture

    /// The surface's frame its host gives it now.
    static func area(_ fixture: Fixture) -> CGSize {
        fixture.session.view.surfaceSize(forHostSize: fixture.session.view.bounds.size)
    }

    /// In a gesture, each layout's bounds are the pane's in that same turn, while one size at a time goes to Ghostty (a new
    /// size per refresh would drop each frame still drawing). After the gesture the last size shows its own frame.
    @Test func aGestureMovesTheBoundsInTheDividersTurnAndTheFrameCatchesUp() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let host = fixture.session.view
        let surface = fixture.session.surfaceView
        host.paneResizeGestureDidChange(active: true)
        var misses: [String] = []
        var asked: Set<CGFloat> = []
        for width in TerminalSurfaceCommitSizeTests.widths {
            fixture.container.terminalWidth = width
            fixture.layoutNow()
            let area = Self.area(fixture)
            if surface.frame.size != area { misses.append("\(width): surface \(surface.frame.size), pane \(area)") }
            if let inFlight = surface.frameOwnership.inFlight { asked.insert(inFlight.width) }
        }
        #expect(misses.isEmpty, "the bounds trailed the pane in the divider's turn: \(misses)")
        // All six layouts ran in one turn: no pass presented between them, so only the first size went to Ghostty.
        #expect(asked.count == 1, "sizes asked of Ghostty in one turn: \(asked.sorted())")
        host.paneResizeGestureDidChange(active: false)
        let last = try #require(TerminalSurfaceCommitSizeTests.widths.last)
        let landed = await fixture.waitShown(width: last)
        #expect(landed, "the last size never showed its own frame (shown \(fixture.shownPixels.map { "\($0)" } ?? "nothing"))")
        let presenter = TerminalFramePresenter.forWindow(fixture.window)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, presenter.isWaiting(surface) { await fixture.commits(1) }
        #expect(surface.frame.size == Self.area(fixture), "at rest the surface is \(surface.frame.size), its pane \(Self.area(fixture))")
        #expect(surface.frameOwnership.boundsAhead == nil, "at rest the bounds are still ahead of a \(String(describing: surface.frameOwnership.boundsAhead)) frame")
        #expect(fixture.layerPixels == fixture.shownPixels, "at rest the layer is \(String(describing: fixture.layerPixels)), its frame \(String(describing: fixture.shownPixels))")
    }

    /// Outside a gesture nothing changes: a size whose frame is not drawn keeps the old bounds (ready-or-keep).
    @Test func outsideAGestureTheBoundsWaitForTheirFrame() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let surface = fixture.session.surfaceView
        let rest = surface.frame.size
        fixture.container.terminalWidth = 520
        fixture.layoutNow()
        let presenter = TerminalFramePresenter.forWindow(fixture.window)
        try #require(presenter.isWaiting(surface), "520 pt did not wait for its frame")
        #expect(surface.frame.size == rest, "outside a gesture the bounds went to \(surface.frame.size) before their frame")
        #expect(!surface.locksBoundsToPane, "a key-less, gesture-less resize locked the bounds to the pane")
        let landed = await fixture.waitShown(width: 520)
        #expect(landed, "520 pt never showed its own frame")
        #expect(fixture.mismatches.isEmpty, "turns with the layer and its frame at different sizes: \(fixture.mismatches.prefix(6))")
    }
}
