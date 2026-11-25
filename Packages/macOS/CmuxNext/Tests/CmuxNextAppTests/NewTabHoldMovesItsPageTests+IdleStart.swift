import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextTestSupport
import Foundation
import Testing

/// The second form of a row of another suite that was written for the pool's path or for the cold path.
///
/// Such a row counts each New Tab page as used before its key (`NewTabOpenFramesTests.useEachNewTabPage`), so its
/// key's tab gets the pool's page or a new one. That is one of the 2 ways of a New Tab key. The other is the default
/// one: the key's tab takes the page view of a New Tab tab that the person did not touch (`AgentTabStore.idlePage`).
/// A row with an argument `used` runs in both forms: `true` is the form above, `false` is the form in which the row's
/// key takes an idle page view, and the row then holds its property for that take.
///
/// Limits. Each page view is a WebKit one. No row here waits for a page's own handshake or sets its mark: a tab
/// takes an untouched page view with or without it, also in a suite whose pages load nothing (an inert address).
extension NewTabHoldMovesItsPageTests {
    /// The setup of the second form in a suite with a whole app: the page view of the New Tab tab that `pane` shows,
    /// which the person did not touch. The tab of the next New Tab key takes this page view while no other pane
    /// draws it.
    static func theIdlePage(of pane: PaneController, _ services: AppServices) async throws -> AgentPaneView {
        let tabs = services.agentTabs
        // Frames of the app until the tab that the pane shows has its page view, 10 seconds at most (as `waitsForItsPage`).
        let start = ContinuousClock.now
        while pane.currentTabKey.flatMap({ tabs.existingView($0) }) == nil, ContinuousClock.now - start < .seconds(10) {
            await NewTabPageAtItsFrameTests.frame(services)
        }
        let shown = try #require(pane.currentTabKey, "setup: the pane shows no tab")
        let view = try #require(tabs.existingView(shown), "setup: the tab that the pane shows has no page view")
        try #require(tabs.isNewTabPage(shown) && view.isUntouchedNewTab,
                     "setup: the pane does not show a New Tab page that the person did not touch (a New Tab page: \(tabs.isNewTabPage(shown)))")
        return view
    }

    /// What a key of the second form did, read when the key's call returned: the page view that the new tab has (nil
    /// also while the pane still shows `left`, the tab that it showed at the key), and the app's record of the open
    /// (`NewTabSparePool.openings`), if the open wrote one after `openings` records.
    static func afterAKey(in pane: PaneController, left: String?, _ services: AppServices, openings: Int) -> (took: AgentPaneView?, record: AgentPaneSpareOpening?) {
        let new = pane.currentTabKey.flatMap { $0 == left ? nil : $0 }
        return (new.flatMap { services.agentTabs.existingView($0) }, services.newTabSpares.openings.dropFirst(openings).first)
    }
}
