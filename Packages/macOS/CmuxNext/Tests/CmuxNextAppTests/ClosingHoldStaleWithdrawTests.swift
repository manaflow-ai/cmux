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
/// the tab earlier, before another took it). That pane is not closing, so the release ran at once, in the motion.
/// The presenter decides first; a withdraw counts only from the pane that owned the tab.
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

        // Cmd-W on pane 2's last tab: the pane leaves in a spring, then the tree drops it (the gone-tab watch releases).
        let prepared = try #require(closing.prepareClose(closing.stripModel.orderedTabs.map(\.id)), "fixture: the close has a daemon tab")
        try #require(app.root.screenViews.values.contains { !$0.isHidden && $0.hasMotion }, "fixture: the close springs")
        app.cache.release(tab)
        #expect(app.cache.existingTerminal(tab) != nil,
                "the release ran in the close's key turn: it asked a pane that does not present the tab, not the closing one")
        await prepared.finish(false, false)
        #expect(app.cache.existingTerminal(tab) != nil, "the reply's release ran in the motion")
        app.settle()
        app.committed.run()
        await Self.drainMain()
        #expect(app.cache.existingTerminal(tab) == nil, "the closed terminal stayed after the landing")
    }
}
