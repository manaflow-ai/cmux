import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// A held New Tab key opens a tab at each key, and each of those tabs is a New Tab page that the person did not
/// touch. Such pages draw one screen: a pane shows one of them at a time, so a pane needs one page view for them,
/// not one for each tab. A page view is a web view with its own process: a hold that makes one for each key pays
/// each make in the frames of the hold, and keeps each page alive behind the tab that is shown.
///
/// The rule of these rows: the untouched New Tab tabs of a pane have ONE page view. It is the page of the tab that
/// the pane shows; when the pane shows another untouched New Tab tab, the page goes with the selection.
///
/// - Row 1: a hold of New Tab keys makes one page view.
/// - Row 2: a walk back over the tabs of a hold makes no page view, and the tabs have one page view all the time.
/// - Row 3: a hold of the Close Tab key over the tabs of a hold: the pane shows the same page view after each
///   close but the last, each close takes the tab that the pane showed, and no page view is made.
/// - Row 4, what must stay: a New Tab tab and a terminal tab shown in turn make no page view.
///
/// The app is the package's own, with a daemon of this tree and an empty pool of pages made ahead, so each page
/// view here is a cold one (the setup of `NewTabPageAtItsFrameTests`). A frame is the app's own: a row waits for
/// one by an event. Each key is the New Tab action's own call (`NewTabPage.open`), each tab switch is the pane's
/// own call (`select`), each close is the pane's own call (`close`): no row sends a key event.
///
/// Limits. The package's tests have no Chromium host, so each page view is a WebKit one. A row that makes more
/// than 2 page views in its hold stops the hold there: a hold that makes a page view for each key must not make
/// 94 web views on the test's Mac. The rows read the count of page views and which view a tab has; they do not
/// read what a page draws.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabHoldMovesItsPageTests {
    /// The pane's tabs that are New Tab pages, in the strip's order, by the keys that they have now (the store can
    /// give a tab a new key when the daemon answers its creation).
    static func newTabs(of pane: PaneController, _ services: AppServices) -> [String] {
        pane.orderedIDs.map(\.rawValue).filter { services.agentTabs.isNewTabPage($0) }
    }

    /// The page views that the pane's New Tab tabs have now.
    static func pages(of pane: PaneController, _ services: AppServices) -> [AgentPaneView] {
        newTabs(of: pane, services).compactMap { services.agentTabs.existingView($0) }
    }

    /// A hold of `keys` New Tab keys with a frame of the app after each. It stops after the key that made the third
    /// page view. Returns the keys pressed, and the most page views that the pane's New Tab tabs had at one time.
    static func hold(_ keys: Int, in pane: PaneController, _ services: AppServices, built: () -> Int) async -> (pressed: Int, most: Int) {
        var pressed = 0, most = 0
        for _ in 0..<keys {
            NewTabPage.open(in: pane, seed: nil)
            await NewTabPageAtItsFrameTests.frame(services)
            pressed += 1
            most = max(most, pages(of: pane, services).count)
            if built() > 2 { break }
        }
        return (pressed, most)
    }

    /// Shows the pane's tab `key` and waits for one frame of the app.
    static func show(_ key: String, in pane: PaneController, _ services: AppServices) async throws {
        let id = try #require(pane.orderedIDs.first { $0.rawValue == key }, "setup: the tab \(key) is not in the strip")
        pane.select(id)
        await NewTabPageAtItsFrameTests.frame(services)
        try #require(pane.currentTabKey == key, "setup: the pane does not show the tab that the row selected, one frame after the select")
    }

    /// Row 1. A hold of 94 New Tab keys, with a frame after each key as a hold at the key repeat rate has. Want: one
    /// page view for the hold, and the pane's New Tab tabs have one page view at each frame.
    @Test(arguments: [94]) func aHoldOfNewTabKeysMakesOnePageView(keys: Int) async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-hold-moves-page-hold") { services, _, pane, built in
            let held = await Self.hold(keys, in: pane, services, built: built)
            let tabs = Self.newTabs(of: pane, services).count
            print("""
                NewTabHoldMovesItsPageTests: row 1, a hold of \(keys) New Tab keys: \(held.pressed) keys pressed, \(built()) page \
                views made, the pane has \(tabs) New Tab tabs, they had \(held.most) page views at one time at most
                """)
            #expect(held.pressed == keys,
                    "the hold stopped after key \(held.pressed) of \(keys): \(built()) page views were made by then, want 1 for the whole hold")
            #expect(built() == 1, "\(built()) page views were made for a hold of \(held.pressed) New Tab keys, want 1")
            #expect(held.most == 1, "the pane's New Tab tabs had \(held.most) page views at one time, want 1")
            let shown = try #require(pane.currentTabKey, "the pane shows no tab after the hold")
            #expect(services.agentTabs.existingView(shown) != nil, "the tab that the pane shows after the hold has no page view")
        }
    }

    /// Row 2. A hold of 6 keys, then the person goes back over the 6 tabs, one tab at each frame. Want: the walk
    /// makes no page view, the tab that the pane shows has a page view at each step, and the 6 tabs have one page
    /// view at each step.
    @Test func aWalkBackOverTheTabsOfAHoldMakesNoPageViewAndKeepsOne() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-hold-moves-page-walk") { services, _, pane, built in
            let held = await Self.hold(6, in: pane, services, built: built)
            let afterTheHold = built()
            let count = Self.newTabs(of: pane, services).count
            try #require(count == held.pressed, "setup: the pane has \(count) New Tab tabs after \(held.pressed) keys")
            var most = 0, steps = 0, withNoPage = 0
            for index in (0..<(count - 1)).reversed() {
                // The key that the tab has now: a tab can get a new key between two steps.
                let key = Self.newTabs(of: pane, services)[index]
                try await Self.show(key, in: pane, services)
                steps += 1
                most = max(most, Self.pages(of: pane, services).count)
                if services.agentTabs.existingView(key) == nil { withNoPage += 1 }
            }
            print("""
                NewTabHoldMovesItsPageTests: row 2, a walk back over \(count) tabs of a hold: \(afterTheHold) page views made in \
                the hold, \(built() - afterTheHold) in the \(steps) steps of the walk; the tabs had \(most) page views at one \
                time at most in the walk; \(withNoPage) steps showed a tab with no page view
                """)
            #expect(built() == afterTheHold, "the walk back made \(built() - afterTheHold) page views in \(steps) steps, want 0")
            #expect(withNoPage == 0, "\(withNoPage) of \(steps) steps showed a tab with no page view")
            #expect(most == 1, "the pane's \(count) New Tab tabs had \(most) page views at one time in the walk, want 1")
        }
    }

    /// Row 3. A hold of 94 New Tab keys, then a hold of the Close Tab key over those tabs, with a frame after each
    /// close. Want: each close takes the tab that the pane showed; after each close but the last, the pane shows the
    /// page view that it showed before the close (the page goes to the tab that is shown next: no page view is
    /// closed before the last tab); and no page view is made at a show.
    @Test(arguments: [94]) func aCloseHoldOverTheTabsOfAHoldKeepsThePageView(keys: Int) async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-hold-moves-page-close") { services, _, pane, built in
            let tabs = services.agentTabs
            let held = await Self.hold(keys, in: pane, services, built: built)
            let afterTheHold = built()
            var closes = 0, outOfOrder = 0, otherPage = 0, noPage = 0
            while Self.newTabs(of: pane, services).count > 1 {
                let shown = try #require(pane.currentTabKey, "setup: the pane shows no tab before close \(closes + 1)")
                try #require(tabs.isNewTabPage(shown), "setup: the pane shows no New Tab tab before close \(closes + 1)")
                let page = tabs.existingView(shown)
                let id = try #require(pane.orderedIDs.first { $0.rawValue == shown }, "setup: the shown tab is not in the strip")
                let before = pane.orderedIDs.count
                pane.close([id])
                await NewTabPageAtItsFrameTests.frame(services)
                closes += 1
                if pane.orderedIDs.contains(id) || pane.orderedIDs.count != before - 1 { outOfOrder += 1 }
                let next = pane.currentTabKey.flatMap { tabs.existingView($0) }
                if next == nil { noPage += 1 } else if next !== page { otherPage += 1 }
            }
            print("""
                NewTabHoldMovesItsPageTests: row 3, a close hold over the tabs of a hold of \(held.pressed) keys: \(closes) closes \
                before the last tab; \(outOfOrder) closes did not take the shown tab; after \(otherPage) closes the pane showed \
                another page view, after \(noPage) closes a tab with no page view; \(built() - afterTheHold) page views made in \
                the close hold
                """)
            #expect(held.pressed == keys, "the hold stopped after key \(held.pressed) of \(keys): \(afterTheHold) page views were made by then")
            #expect(outOfOrder == 0, "\(outOfOrder) of \(closes) closes did not take the tab that the pane showed, and only that tab")
            #expect(otherPage == 0, "after \(otherPage) of \(closes) closes the pane showed another page view than before the close: the page did not go to the tab that is shown next")
            #expect(noPage == 0, "after \(noPage) of \(closes) closes the pane showed a tab with no page view, one frame after the close")
            #expect(built() == afterTheHold, "the close hold made \(built() - afterTheHold) page views, want 0")
        }
    }

    /// Row 4, what must stay. One New Tab tab, and the tab that the pane had before it (a terminal). The person shows
    /// the 2 tabs in turn 20 times, one tab at each frame. Want: no page view is made, and the New Tab tab has a page
    /// view each time that the pane shows it.
    @Test func aNewTabTabAndATerminalTabShownInTurnMakeNoPageView() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-hold-moves-page-turns") { services, _, pane, built in
            let tabs = services.agentTabs
            let before = try #require(pane.currentTabKey, "setup: the pane shows no tab before the key")
            try #require(!tabs.isNewTabPage(before), "setup: the pane shows a New Tab page before the key")
            NewTabPage.open(in: pane, seed: nil)
            await NewTabPageAtItsFrameTests.frame(services)
            try #require(built() == 1, "setup: the New Tab key made \(built()) page views by its frame, want 1")
            var withNoPage = 0
            for _ in 0..<20 {
                try await Self.show(before, in: pane, services)
                let newTab = try #require(Self.newTabs(of: pane, services).first, "setup: the pane has no New Tab tab")
                try await Self.show(newTab, in: pane, services)
                if tabs.existingView(newTab) == nil { withNoPage += 1 }
            }
            print("""
                NewTabHoldMovesItsPageTests: row 4, a New Tab tab and a terminal tab shown in turn 20 times: \(built() - 1) page \
                views made in the turns; \(withNoPage) times the New Tab tab had no page view when the pane showed it
                """)
            #expect(built() == 1, "the 20 turns made \(built() - 1) page views, want 0")
            #expect(withNoPage == 0, "\(withNoPage) of 20 times the New Tab tab had no page view, one frame after the pane showed it")
        }
    }
}
