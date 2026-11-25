import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// The made-ahead workspace and the count of page views.
///
/// A window makes the workspace of the next New Workspace key ahead (`WindowController.reservedContent`), with a page
/// view for its New Tab page. It makes it as background work on the app's frame scheduler: after it shows a
/// workspace, after it becomes the key window, and when the app's hibernation level goes back to normal. That work
/// yields to input that waits and to a frame with no idle time. A New Tab key that the app handled already is not
/// input that waits. So a New Tab key that comes while the window makes that workspace can have a second page view
/// made beside its own, in the frames of the key. A New Tab key starts no such work: a key in a window that has its
/// made-ahead workspace gets its own page view only (`aRunOfNewTabKeysInOneTurnMakesNoPageBeforeAFrameAndOneAtMostAfterIt`).
///
/// Each page view here is a real one and its engine is WebKit (the package's tests have no Chromium host).
extension NewTabPageAtItsFrameTests {
    /// The page views `pages` in words, for a row's print and its failure text: their count, each one's key with what
    /// its tab is (the window's made-ahead tab, the pane's selection when the view was made, another tab of the pane,
    /// or none of these), and the key of the made-ahead tab (`none`: the store has no made-ahead workspace).
    static func pagesInWords(_ pages: [BuiltPage], _ pane: PaneController, _ services: AppServices) -> String {
        let tabs = services.agentTabs
        let ahead = services.daemon.store.reservedWorkspace?.tabKey
        let ofThePane = Set(pane.orderedIDs.map { tabs.resolve($0.rawValue) })
        var words: [String] = []
        for page in pages {
            var what = "no tab of the pane and not the made-ahead tab"
            if page.key == ahead {
                what = "the made-ahead tab"
            } else if page.selected {
                what = "the pane's selection then"
            } else if ofThePane.contains(tabs.resolve(page.key)) {
                what = "a tab of the pane"
            }
            words.append("\(page.key) (\(what))")
        }
        return "\(pages.count) page views \(words); the made-ahead tab's key \(ahead ?? "none")"
    }

    /// ONE New Tab key in the turn in which the window starts to make its workspace ahead, from no made-ahead
    /// workspace and an empty pool. The row wants what the app does then: 2 page views, one for the key's tab and one
    /// for the made-ahead tab, and no third. It wants no page view in the key's own turn (the frame rule).
    ///
    /// It prints ONE line that starts `MADE AHEAD BESIDE A KEY:`, on a pass also: each page view by its key, whose
    /// it is, and when it was made (in the key's own turn, before the end of the key's first frame, or after that
    /// frame), and if the made-ahead tab's page view came before the end of the key's first frame. The row does not
    /// assert that order: the scheduler gives the background work its turn by the idle time of a frame, and no row
    /// fixes that. The key's first frame is the app's own (`frame`). The wait after it is the base's wait of the
    /// setup, with a deadline.
    @Test func aNewTabKeyWhileTheWindowMakesItsWorkspaceAheadHasThatPageViewBesideItsOwn() async throws {
        let row = "cn-page-at-frame-made-ahead"
        try await Self.withThePagesOfAnEmptyPool(row) { services, _, pane, builds in
            let tabs = services.agentTabs
            let store = services.daemon.store
            let controller = try #require(services.windows.active, "setup: no window")
            // From no made-ahead workspace: the window's first show can have made one already, and a fill then does
            // nothing. The page view of the workspace that the setup lets go can go back to the pool, so the setup
            // empties the pool again.
            controller.reservedContent.drop()
            tabs.releaseReservedWorkspace(on: store, .unshown)
            services.newTabSpares.dropAll()
            NewTabOpenFramesTests.useEachNewTabPage(services)
            let noneAhead = store.reservedWorkspace == nil && controller.reservedContent.ready == nil
            try #require(noneAhead, "setup: the window still has a made-ahead workspace")
            let atTheSetup = builds().count

            controller.reservedContent.fill()
            NewTabPage.open(in: pane, seed: nil)
            let made = try #require(pane.stripModel.selectedID?.rawValue, "the open selected no tab")
            try #require(tabs.isNewTabPage(made), "the open did not select its New Tab page")
            let inTheKeysTurn = builds().count
            await Self.frame(services)
            let atTheFirstFrame = builds().count
            try await PasswordManagerRouteTests.until({
                controller.reservedContent.ready != nil && store.reservedWorkspace != nil
                    && pane.currentTabKey.flatMap({ tabs.existingView($0) }) != nil
            }, within: .seconds(10), report: { "the window made no workspace ahead, or the key's tab got no page view" })
            let ahead = try #require(store.reservedWorkspace?.tabKey, "the store has no made-ahead workspace after the wait")

            let keysTab = tabs.resolve(made)
            let all = builds()
            var own = 0, forAhead = 0, other = 0, aheadBeforeTheFramesEnd = false
            var words: [String] = []
            for position in atTheSetup..<all.count {
                let key = all[position].key
                var when = "after the key's first frame"
                if position < inTheKeysTurn {
                    when = "in the key's own turn"
                } else if position < atTheFirstFrame {
                    when = "before the end of the key's first frame"
                }
                var whose = "no tab of the 2"
                if key == ahead {
                    whose = "the made-ahead tab"
                    forAhead += 1
                    if position < atTheFirstFrame { aheadBeforeTheFramesEnd = true }
                } else if key == made || tabs.resolve(key) == keysTab {
                    whose = "the key's tab"
                    own += 1
                } else {
                    other += 1
                }
                words.append("\(key) (\(whose), \(when))")
            }
            var state = "the key's tab \(made), its key now \(keysTab); the made-ahead tab \(ahead); "
            state += "\(all.count - atTheSetup) page views in the count: \(words); "
            state += "the made-ahead tab's page view came before the end of the key's first frame: \(aheadBeforeTheFramesEnd)"
            print("MADE AHEAD BESIDE A KEY: NewTabPageAtItsFrameTests \(row): \(state)")
            #expect(inTheKeysTurn == atTheSetup, "\(inTheKeysTurn - atTheSetup) page views were made in the key's own turn: \(state)")
            #expect(own == 1, "the key's tab had \(own) page views: \(state)")
            #expect(forAhead == 1, "the made-ahead tab had \(forAhead) page views: \(state)")
            #expect(other == 0, "\(other) page views were for a tab that is not the key's and not the made-ahead tab: \(state)")
        }
    }
}
