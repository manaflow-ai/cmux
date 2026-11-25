import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextFocus
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// The slow-page close gap (cmux20-bench films, pane-perf --browser 4x2 close, a page that takes 30 ms per resize): a
/// pane close shown in its key's turn (`PaneController.showPaneClose`) sent its focus topology first, and the window's
/// applier granted the page beside the closed pane the keys there (CEF `SetFocus`, its page window made key, 1 to 3 ms
/// after the key). The layout sync after it then gave that page its next size ahead of the commit (3 to 14 ms). In about
/// half of the closes the page's frames then stopped from about 56 ms to 125 to 157 ms after the key, and the commit that
/// waited for it showed its old frame beside the backdrop. Zooms take the same draw-ahead with no grant and never stalled.
///
/// The rule: a close's focus goes with its layout, and a page grant waits for the layout. The close's focus is sent
/// inside the applier's `holdingPageGrants(_:until:)` and its layout is that call's `until`: the page the layout drew
/// ahead for the commit keeps its ask until the commit ends (`CEFTabContentView.endCommitAhead`).
@Suite(.closesItsWindows)
@MainActor struct PaneCloseFocusAfterLayoutTests {
    typealias Shown = PaneCloseControllerTests.Shown

    /// Records what the close's focus effects and its layout found.
    final class Recorder: FocusEffectApplying {
        var screen: ScreenContentView?
        private var holding = false
        /// Per effects batch: whether it applied inside a page-grant hold.
        private(set) var applies: [Bool] = []
        /// Per hold: whether the screen gave its resized panes their sizes ahead by the hold's end.
        private(set) var holdEnds: [Bool] = []

        func apply(_ effects: [FocusEffect], state: FocusState) {
            applies.append(holding)
        }

        func holdingPageGrants(_ send: () -> Void, until layout: () -> Void) {
            holding = true
            send()
            holding = false
            layout()
            holdEnds.append(screen?.frameInput.snapWaitsForContent == true)
        }
    }

    /// The right column's focused pane closes: its focus effects (the left pane takes the focus) apply inside a hold of
    /// page grants that ends once, after the screen gave the left pane its next size ahead.
    @Test func aPaneClosesFocusAppliesInsideAPageGrantHoldThatEndsAfterItsLayoutDrewAhead() async throws {
        let shown = try Shown([ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(1)), ColumnSnapshot(id: 11, width: 0.5, layout: .leaf(2))])
        defer { shown.end() }
        let root = shown.content.layoutView
        root.context.reduceMotionOverride = false
        root.driver.isManual = true
        root.context.afterCommit = { _ in } // the closed pane's teardown is not part of this test
        try shown.focus(2)
        await PaneCloseKeyTurnTests.drainTurns()
        root.layoutSubtreeIfNeeded()
        let screenID = try #require(shown.content.layoutModel.screens.first?.id)
        let left = try shown.key(1)
        let recorder = Recorder()
        recorder.screen = try #require(root.screenViews[screenID])
        shown.state.focus.applier = recorder

        _ = try #require(try shown.controller(2).showPaneClose(), "the right column's only pane waited for the daemon's tree")
        #expect(shown.state.focus.state.pane == left, "the close did not move the focus to the left pane")
        #expect(!recorder.applies.isEmpty, "the close's focus applied no effects")
        #expect(recorder.applies.allSatisfy { $0 }, "the close's focus effects applied outside a page-grant hold: \(recorder.applies)")
        #expect(recorder.holdEnds == [true], "the close's page-grant hold did not end once, after its layout drew ahead: \(recorder.holdEnds)")
    }
}
