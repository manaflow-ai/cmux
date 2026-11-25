import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// The opening of a New Tab page made by hand, for the 2 suites whose window has a store with a fixed tree and no
/// daemon (`NewTabHoldCloseKeyTests`, `NewTabHoldFocusTests`). The product's open (`NewTabPage.open`) asks the daemon
/// for its tab and makes its own page. These suites have no daemon, and each needs a page of its own whose field
/// never reports ready.
///
/// What the by-hand opening keeps from the product's open: the hold begins while the pane shows the tab that it had,
/// the page is in ANOTHER tab, and the pane shows that tab after the hold began. A hold whose page is in the tab of
/// the key is the state `the person went back to the tab of the key`, where the hold does not own the window's keys
/// (`NewTabInputCoordinator.Entry.owns`). No opening of the product makes that state: the rows
/// `theNewTabsPageIsNotInTheTabThatThePaneShowedAtTheKey` (the web page's open) and
/// `keysTypedBeforeTheFieldExistsLandInIt` (the native page's open) hold it.
@MainActor enum NewTabHoldByHandOpening {
    /// The tab for the page of an opening in `pane`: the tab of the pane that it does not show. `shownTab` (a hold
    /// of no opening in this pane: Cmd-N's, New Window's): the tab that the pane shows.
    static func pagesTab(of pane: PaneController, shownTab: Bool = false) throws -> String {
        let shown = try #require(pane.currentTabKey, "the pane shows no tab")
        if shownTab { return shown }
        let tabs = pane.orderedIDs.map(\.rawValue)
        return try #require(tabs.first { $0 != shown }, "the pane has no second tab for the page: its tabs \(tabs), it shows \(shown)")
    }

    /// The opening shows its page: the pane goes from the tab of the key to the page's tab `tab`, and then the hold
    /// hears that the page showed (`didShow`), as `NewTabPage.open` tells it after the new tab's show. The tab switch
    /// is the pane's own call (`select`), which gives the pane focus: after the switch the focus model names
    /// `focused` again, and `keyboard` has the keyboard again, as before the opening.
    static func showsItsPage(in tab: String, of pane: PaneController, hold input: NewTabInputCoordinator, controller: WindowController,
                             focused: PaneController, keyboard: NSView?) async throws {
        let window = try #require(pane.view.window, "the pane is in no window")
        let atTheKey = try #require(pane.currentTabKey, "the pane showed no tab when the hold began")
        try #require(atTheKey != tab, "the page is in the tab that the pane showed when the hold began (\(tab)): no opening makes this")
        let id = try #require(pane.orderedIDs.first { $0.rawValue == tab }, "the page's tab \(tab) is not in the pane's strip")
        pane.select(id)
        // One frame at least: a tab whose content the pane must make shows at the pane's next frame.
        await NewTabPageAtItsFrameTests.frame(pane.services)
        for _ in 0..<3 where pane.currentTabKey != tab { await NewTabPageAtItsFrameTests.frame(pane.services) }
        let shown = pane.currentTabKey ?? "no tab"
        try #require(shown == tab, "the pane does not show the page's tab \(tab) after the tab switch: it shows \(shown)")
        let page = try #require(pane.services.agentTabs.existingView(tab), "the page's tab \(tab) has no page view after the tab switch")
        try #require(page.window === window && !page.isHiddenOrHasHiddenAncestor, "the page is not shown in the window after the tab switch")
        controller.focus.send(.focusPane(focused.paneKey, source: .programmatic))
        let named = controller.focus.state.pane ?? "no pane"
        try #require(named == focused.paneKey, "the focus model names \(named) after the tab switch, not the pane that had focus before the opening")
        if let keyboard {
            let had = String(describing: window.firstResponder)
            try #require(window.firstResponder === keyboard || window.makeFirstResponder(keyboard), "the view that had the keyboard before the opening did not take it again after the tab switch (first responder \(had))")
            try #require(window.firstResponder === keyboard, "the view that had the keyboard before the opening does not have it after the tab switch")
        }
        try #require(input.isHolding(in: window), "the hold ended at the tab switch, before the page showed: \(input.log)")
        input.didShow(in: window)
    }
}
