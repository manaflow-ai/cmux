import AppKit
@testable import CmuxNextApp
import Testing

extension NewTabPageAtItsFrameTests {
    /// The key hold does not own its window's keys when its pane shows again the tab that it showed at the key, after
    /// the new tab's page showed (`NewTabInputCoordinator.Entry.owns`): the person went back to that tab. That rule is
    /// right only while an opening puts its page in ANOTHER tab than the tab of the key. An opening that puts its page
    /// in the tab of the key would have a hold that holds no key.
    ///
    /// This row holds it for the web page's open (`NewTabPage.open`), with the hold's own record of the tab that the
    /// pane showed when the hold began (its log). `NativeNewTabTypeAheadTests` holds it for the native page's open.
    /// The by-hand opening of the suites with no daemon (`NewTabHoldByHandOpening`) copies this order.
    @Test func theNewTabsPageIsNotInTheTabThatThePaneShowedAtTheKey() async throws {
        try await Self.withAnEmptyPool("cn-page-at-frame-tab-at-key") { services, window, pane, _ in
            let input = services.keyRouter.newTabInputCoordinator
            let tabs = services.agentTabs
            let atTheKey = try #require(pane.currentTabKey, "setup: the pane shows no tab before the key")
            NewTabPage.open(in: pane, seed: nil)
            try #require(input.isHolding(in: window), "the open began no key hold")
            let begun = try #require(input.log.last { $0.hasPrefix("begin page opened=") }, "the hold's log has no begin: \(input.log.suffix(4))")
            #expect(begun.hasPrefix("begin page opened=\(atTheKey) "), "the hold did not begin with the tab that the pane showed before the key (\(atTheKey)): \(begun)")
            let made = try #require(pane.stripModel.selectedID?.rawValue, "the open selected no tab")
            try #require(tabs.isNewTabPage(made), "the open did not select its New Tab page")
            #expect(made != atTheKey && made != tabs.resolve(atTheKey), "the open put its page in the tab that the pane showed at the key (\(atTheKey)): the hold reads that tab as the one that the person went back to")
            await Self.frame(services)
            // The hold's own check, one frame after the open: a hold that the pane's tab does not own ends here.
            input.flush(in: window)
            let shown = pane.currentTabKey ?? "no tab"
            #expect(shown != atTheKey && shown != tabs.resolve(atTheKey), "one frame after the open the pane shows the tab of the key (\(atTheKey)), not the new tab \(made)")
            #expect(!input.log.contains { $0.contains("not owned") }, "the hold ended as not owned, one frame after the open (the pane shows \(shown), the tab of the key \(atTheKey)): \(input.log.suffix(6))")
        }
    }
}
