import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// RESIZE VIDEOS F1 (STATUS 7085): on feat the #32197 hold missed in the real app. The suite's xctrace rounds on feat
/// builds showed the gone-tab release of the closed tab running 2-6 ms after the close started, in the key turn
/// (`TabContentCache.release` -> `PaneController.surfaceWasDisplaced` -> `TerminalEntry.close`), while a pane
/// still presented it. `release` asked the pane that last withdrew the tab before the pane that presents it, and
/// `withdraw` recorded a pane even when the ledger ignored its withdraw (it did not own the tab: a pane that showed
/// the tab earlier, before another took it). That pane is not closing, so the release ran at once, in the turns that
/// show the close. The presenter decides first; a withdraw counts only from the pane that owned the tab. A closing pane
/// holds the release until it is torn down, after the commit of the frame that shows the close
/// (`LayoutViewContext.afterClosing`).
@Suite(.closesItsWindows)
@MainActor struct ClosingHoldStaleWithdrawTests {
    private static func drainMain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    @Test(.timeLimit(.minutes(1)))
    func aWithdrawByAPaneThatDoesNotOwnTheTabDoesNotLoseTheHold() async throws {
        let app = try await ClosedPaneContentStaysUntilLandingTests.Fixture()
        defer { app.close() }
        let closing = try app.pane(2), other = try app.pane(1), tab = try app.tab(2)
        try #require(app.cache.presenter(of: tab) === closing, "fixture: pane 2 presents its terminal")
        // A pane that does not own the tab withdraws it (it showed it once, before pane 2 took it): the ledger ignores it.
        app.cache.withdraw(tab, by: other)
        try #require(app.cache.presenter(of: tab) === closing, "fixture: the ledger still has pane 2 as the tab's presenter")

        // Cmd-W on pane 2's last tab: the pane leaves the layout in this turn (a close is one commit), and its host stays
        // until the close shows and is torn down after that. Then the tree drops it (the gone-tab watch releases).
        let prepared = try #require(closing.prepareClose(closing.stripModel.orderedTabs.map(\.id)), "fixture: the close has a daemon tab")
        let screen = try #require(app.root.screenViews.values.first { !$0.isHidden }, "fixture: no screen shows")
        try #require(app.root.context.isClosing(closing.layoutPaneID), "fixture: the layout does not keep the closing pane's host")
        app.cache.release(tab)
        #expect(app.cache.existingTerminal(tab) != nil,
                "the release ran in the close's key turn: it asked a pane that does not present the tab, not the closing one")
        await prepared.finish(false, false)
        #expect(app.cache.existingTerminal(tab) != nil, "the reply's release ran before the closed pane was torn down")
        // The frame tick that shows the close (a close that resizes no pane showed in its own turn): it carries no teardown.
        _ = app.root.advanceFrame(ClosedPaneContentStaysUntilLandingTests.dt)
        #expect(!screen.frameInput.snapWaitsForContent, "the close did not show at its first frame tick")
        #expect(app.cache.existingTerminal(tab) != nil, "the frame that shows the close tore the terminal down, before its commit")
        // That frame's commit tears the closed pane down, and the releases held for the pane run after that turn's commit.
        app.committed.run()
        app.committed.run()
        await Self.drainMain()
        #expect(app.cache.existingTerminal(tab) == nil, "the closed terminal stayed after the close showed and its pane was torn down")
    }
}
