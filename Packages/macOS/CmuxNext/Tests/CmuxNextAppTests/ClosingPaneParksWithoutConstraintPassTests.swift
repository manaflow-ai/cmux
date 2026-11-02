import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// RESIZE VIDEOS F1 close fix (a) (STATUS 7551): a close's second frame missed its refresh partly on a constraints pass
/// over the whole window (`updateConstraintsForSubtreeIfNeeded`, 2 ms of 20 in the commit). The closing pane's frame
/// presentation parks its terminal (`PaneContentView.retire`), and parking wrote `autoresizingMask = []`, whose setter
/// calls `setNeedsUpdateConstraints` up to the window. A parked view's mask waits for the motion to land: no view in
/// the close's motion frames asks for a constraints pass.
@Suite(.closesItsWindows)
@MainActor struct ClosingPaneParksWithoutConstraintPassTests {
    @Test(.timeLimit(.minutes(1)))
    func parkingInACloseMotionAsksForNoConstraintPass() async throws {
        let app = try await ClosedPaneContentStaysUntilLandingTests.Fixture()
        defer { app.close() }
        let closing = try app.pane(2), closedTab = try app.tab(2)
        let terminal = try #require(app.cache.existingTerminal(closedTab)?.session.view, "fixture: pane 2's terminal exists")
        try #require(terminal.superview === closing.view.contentHost, "fixture: pane 2 shows its terminal")
        app.window.contentView?.updateConstraintsForSubtreeIfNeeded()
        try #require(!terminal.needsUpdateConstraints, "fixture: no constraints pass pending at rest")

        _ = try #require(closing.prepareClose(closing.stripModel.orderedTabs.map(\.id)), "fixture: the close has a daemon tab")
        try #require(app.root.isInLayoutMotion, "fixture: the close springs")
        // The next frame's content presentation: the closing pane parks the terminal its strip no longer lists.
        closing.showSelected()
        try #require(terminal.superview === closing.view.contentHost && terminal.isHidden, "fixture: the terminal is parked, hidden")
        #expect(!terminal.needsUpdateConstraints,
                "parking in the close's motion asked for a constraints pass over the window (autoresizingMask written)")
        #expect(terminal.autoresizingMask == [.width, .height], "the mask changed in the motion")
    }

    @Test func parkingAtRestStillStopsTheViewFollowingThePane() throws {
        let view = PaneContentView(stripModel: TabStripModel(), reveal: LaunchReveal(deadline: .zero))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let first = ParkableTestView(), second = ParkableTestView()
        view.show(first)
        view.show(second)
        #expect(first.isHidden && first.autoresizingMask.isEmpty, "a view parked at rest still follows the pane")
        #expect(second.autoresizingMask == [.width, .height])
    }
}

private final class ParkableTestView: NSView, PaneParkableContent {}
