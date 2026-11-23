import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextFocusUI
@testable import CmuxNextPages
import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Rows 9 and 10. Two parts of the key hold's rules for the tab that the pane showed at the New Tab key (the tab of
/// the key), which no other row of the suite holds.
///
/// Row 9, the hold's read of a page view that its tab took (`NewTabInputCoordinator.tookPage`). When the new tab
/// takes the page view that had the keyboard at the key, the person left nothing, and a hold that ends with no field
/// ready gives its keys to that view (rows 6, 7 and 8). The read does not count a page view that the tab of the key
/// still has: the selection did not move then, so that view is what the person left, and it gets no key of the hold.
/// By a read, no open of the product calls `tookPage` in that state: after the open the pane has the new tab
/// selected. So the row makes the state by hand: it begins a hold while the pane shows the first new tab, as the
/// New Tab key does, opens no tab, and calls `tookPage` itself. Want: at the hold's limit the letter is not given to
/// the page view of the tab of the key. The hold's log has the line `dropped 1 keys`, and that view has no mark of
/// a key from the host.
///
/// Row 10, the tab of the key by the id that the daemon gave it (`Entry.owns`). The second New Tab key comes while
/// the creation of the first new tab still waits, so the hold knows the tab of the key by its first id. The daemon
/// then makes that tab, and the pane lists it by the id of the daemon's tab. The person goes back to it. Want, as in
/// row 1: a letter that the person types there, with a ready field, goes to that tab at once. The second tab's hold
/// does not keep it. The row has 2 cases, by what the app knows at the letter. The app knows the first id of a tab
/// that the daemon made (`AgentTabStore.resolve`) until the daemon's tree no longer lists that id, and it forgets
/// it then (`releaseGoneTabs`). Case `known`: the app still knows the first id at the letter. Case `forgotten`: it
/// does not, which is the state after the daemon's tree settled.
///
/// Limits. Row 9 calls `tookPage` by hand, so it holds the rule of that read and no flow of a person. In row 10 the
/// test is the daemon: it applies the event of the new tab to the window's store, and then it answers the creation.
/// Row 10 has that one order of the daemon's answer and the person's way back. It makes each case sure by hand at
/// the letter: when the app forgot the first id before a letter of case `known`, the row writes it again, and when
/// the app still knows it before a letter of case `forgotten`, the row takes it out; the print says if the row did.
/// Both rows have the WebKit page host, and no page loads.
///
/// What no row holds. The hold keeps each id that the tab of the key had in the hold's life: the pane's id and the
/// app's id of it at the hold's begin (`Entry.init`), and the app's id again when the daemon made the tab
/// (`tabMade`). Row 10 holds the second part. No row holds the first part, or a pane that still has the first id of
/// a tab after the daemon made it. By a read, a pane that has such a tab selected, with its page view, takes the
/// daemon's id in the turn of the store's report (`PaneController.selectWhenReported`), so the scene has no turn
/// with that state. Those parts are by a read. 3 cases are known and not mended, the same as before the hold kept
/// more than one id: a hold that begins while the pane has the first id of a tab and the app forgot that id; a pane
/// that shows no tab at the hold's begin; 2 machines that have a tab with the same first id (a first id has a UUID).
extension NewTabHoldInTheFirstNewTabTests {
    /// One new tab of a row: its page reported, and that page's web view has the keyboard.
    @MainActor struct One {
        let tab: String
        let view: AgentPaneView
        let page: PageInputReadiness
        /// At the report of the page, the app gave that page's web view the keyboard, with no act of the row.
        let keyboardByTheApp: Bool
    }

    /// Row 9. A hold whose tab took no page view: the page view of the tab of the key gets no key of the hold.
    @Test func aHoldDoesNotCountThePageViewOfTheTabOfTheKeyAsTaken() async throws {
        try await Self.withScene { scene in
            let typed = Typed()
            let one = try await scene.firstNewTab(typed)
            try #require(scene.pane.currentTabKey == one.tab, "setup: the pane does not show the first new tab")
            try #require(!one.view.model.hostTouch.marked,
                         "setup: the page view of the first new tab has the host's mark before the letter (by \(one.view.model.hostTouch.by ?? "none")): the row then proves nothing")
            // The hold by hand, as the New Tab key begins it: the pane shows the first new tab, and its page's web
            // view has the keyboard. No tab opens, so the selection does not move.
            let token = scene.input.begin(for: scene.pane)
            try #require(token != nil && scene.input.isHolding(in: scene.window),
                         "setup: the hold by hand did not begin. The hold's log ends: \(scene.holdLog)")
            try #require(scene.pane.currentTabKey == one.tab && scene.services.agentTabs.existingView(one.tab) === one.view,
                         "setup: the tab of the key does not have its page view after the hold began")
            // By hand: by a read no open of the product makes this call while the tab of the key is still selected.
            scene.input.tookPage(in: scene.pane)

            let key = try scene.keys.press("b", code: 11, command: false)
            let held = key.took && scene.input.log.last?.hasPrefix("hold key #") == true
            try #require(held, "setup: the hold by hand did not take the letter. The hold's log ends: \(scene.holdLog)")
            try #require(scene.window.firstResponder === one.view.webView,
                         "setup: the web view of the first new tab's page does not have the keyboard at the hold's limit")
            try scene.passTheLimit()
            let ended = !scene.input.isHolding(in: scene.window)
            let dropped = scene.dropped
            let touch = (marked: one.view.model.hostTouch.marked, by: one.view.model.hostTouch.by)
            await LargeSessionWindowFixture.drainMain()
            print("""
                NewTabHoldInTheFirstNewTabTests: row 9, a hold by hand in the first new tab, the read of a taken page view \
                by hand, a letter, then the hold's limit: the hold ended at its limit: \(ended); the hold's lines of dropped \
                keys: \(dropped); the host's mark on the page view of the tab of the key: \(touch.marked), by \
                \(touch.by ?? "none"); the app made the edits \(typed.into(one.tab)) in that tab's page; the app gave the \
                page's web view the keyboard at its report: \(one.keyboardByTheApp); the test's view got \(scene.old.keys) \
                keys; the hold's log ends: \(scene.holdLog)
                """)
            try #require(ended, "setup: the hold by hand was still there after the row ran its deadline. The hold's log ends: \(scene.holdLog)")
            #expect(dropped.count == 1 && dropped.first?.hasPrefix("dropped 1 keys") == true,
                    """
                    the hold gave its letter on at its limit, and its tab took no page view: the hold's lines of dropped \
                    keys are \(dropped), want one line `dropped 1 keys`. The hold's log ends: \(scene.holdLog)
                    """)
            #expect(!touch.marked,
                    """
                    the page view of the tab of the key got a key of the hold (the host's mark by \(touch.by ?? "none")): \
                    that view is what the person left, and the hold's tab took no page view
                    """)
            #expect(scene.old.keys == 0, "the view that had the keyboard before the New Tab key got \(scene.old.keys) keys, want 0")
        }
    }

    /// Row 10. The daemon makes the first new tab while the second tab's hold is open, and the person goes back to
    /// the first new tab: a letter there is not kept by the second tab's hold. `known`: the app knows the first id of
    /// that tab at the letter.
    @Test(arguments: [true, false])
    func aLetterInTheFirstNewTabThatTheDaemonMadeInTheHoldIsNotKeptByTheSecondTabsHold(known: Bool) async throws {
        try await Self.withScene { scene in
            let tabs = scene.services.agentTabs
            // The creations of this row wait for the row's own answer.
            let answers = NewTabKeySessionWalkTests.HeldAnswers()
            defer { answers.refuseTheRest() }
            tabs.create = { pane, _, record, _, transaction, _ in
                try await answers.wait(NewTabKeySessionWalkTests.HeldAnswers.Ask(pane: pane, record: record, transaction: transaction))
            }
            let typed = Typed()
            let made = try await scene.twoNewTabs(typed)
            let daemons = try await scene.daemonMakesTheFirstNewTab(made, answers)
            let real = daemons.real
            let afterTheAnswer = tabs.resolve(made.tab1) == real
            // The case, before the way back (the report of the page there can end the hold) and again before the letter.
            let wroteBeforeTheWayBack = scene.makesSure(known: known, first: daemons.first, of: real)
            let two = Two(tab1: real, tab2: made.tab2, onePage: made.onePage, keyboardByTheApp: made.keyboardByTheApp)
            let back = try await scene.backToTheFirstNewTab(two, typed)
            let wroteBeforeTheLetter = scene.makesSure(known: known, first: daemons.first, of: real)
            try #require((tabs.resolve(made.tab1) == real) == known, "setup: the case of the row is not there at the letter")
            let holdBefore = scene.input.isHolding(in: scene.window), keptBefore = scene.kept.count, keyboard = scene.keyboard(two)

            let key = try scene.keys.press("a", code: 0, command: false)
            await LargeSessionWindowFixture.drainMain()
            let got = (first: typed.into(real), second: typed.into(made.tab2))
            let keeps = scene.input.isHolding(in: scene.window), kept = scene.kept.count - keptBefore
            print("""
                NewTabHoldInTheFirstNewTabTests: row 10, case \(known ? "known" : "forgotten"), the daemon made the first new \
                tab in the second tab's hold, then a letter in the first new tab: the key router took the letter: \(key.took); \
                the hold kept \(kept) keys at the letter; the app made the edits \(got.first) in the first new tab's page and \
                \(got.second) in the second new tab's page; a key hold was there before the letter: \(holdBefore), after it: \
                \(keeps); the app knew the first id of the tab after the daemon's answer: \(afterTheAnswer); the row changed \
                by hand what the app knew before the way back: \(wroteBeforeTheWayBack), before the letter: \
                \(wroteBeforeTheLetter); the 2 new tabs had one page view: \(made.onePage); the keyboard at the letter: \
                \(keyboard) (by the tab switch: \(back.keyboardByTheSwitch)); the row reported the page ready again after the \
                tab switch: \(back.reportedAgain); the test's view got \(scene.old.keys) keys; the hold's log ends: \(scene.holdLog)
                """)
            #expect(!key.took || got.first == [.insert("a")],
                    """
                    a letter that was pressed in the first new tab, whose field is ready, did not go to that tab after the \
                    daemon made the tab (the app knew the tab's first id: \(known)): the key router took the key, and the app \
                    made the edits \(got.first) in that tab's page. A key hold was there after the letter: \(keeps). The \
                    hold's log ends: \(scene.holdLog)
                    """)
            #expect(kept == 0,
                    """
                    the second tab's hold kept \(kept) keys at the letter in the first new tab, want 0 (the app knew the \
                    tab's first id: \(known)). The hold's log ends: \(scene.holdLog)
                    """)
            #expect(got.second.isEmpty, "the app made the edits \(got.second) in the page of the second new tab, want none")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the first New Tab key got \(scene.old.keys) keys, want 0")
            try await scene.stillReads(back.page, into: typed)
        }
    }
}

extension NewTabHoldInTheFirstNewTabTests.Scene {
    /// New Tab key; the page of the new tab reports with the token of its key hold, as the page does, and its field
    /// reports ready; that page's web view has the keyboard, as in the app after the page's report or after a click
    /// in the page.
    func firstNewTab(_ typed: NewTabHoldInTheFirstNewTabTests.Typed) async throws -> NewTabHoldInTheFirstNewTabTests.One {
        let tab = try newTab()
        await NewTabHoldInTheFirstNewTabTests.frame(services)
        let page = try #require(self.page(of: tab, into: typed), "setup: the first new tab has no page with a field after one frame of the app")
        try #require(!page.isReady, "setup: the field of the first new tab's page is ready after one frame, with no report")
        let token = try #require(self.token(of: tab), "setup: the page of the first new tab has no token of a key hold")
        input.acknowledge(token, in: window)
        page.receive(true)
        await LargeSessionWindowFixture.drainMain()
        try #require(!input.isHolding(in: window) && page.isReady,
                     """
                     setup: the key hold of the first new tab did not end at its page's report (a hold is there: \
                     \(input.isHolding(in: window)), the field is ready: \(page.isReady)). The hold's log ends: \(holdLog)
                     """)
        let view = try #require(services.agentTabs.existingView(tab), "setup: the first new tab has no page view")
        let byTheApp = window.firstResponder === view.webView
        if !byTheApp {
            try #require(window.makeFirstResponder(view.webView) && window.firstResponder === view.webView,
                         "setup: the web view of the first page did not take the keyboard")
        }
        return NewTabHoldInTheFirstNewTabTests.One(tab: tab, view: view, page: page, keyboardByTheApp: byTheApp)
    }

    /// The daemon makes the first new tab of `made` while the second tab's hold is open: the event of the new tab,
    /// with the transaction of the tab's creation, and then the answer of that creation. Returns the id that the
    /// pane lists the tab by after it (`real`), and the key by which the app knew the first id of the tab directly
    /// after the event (`first`). The pane still shows the second new tab, and its hold is still open.
    func daemonMakesTheFirstNewTab(_ made: NewTabHoldInTheFirstNewTabTests.Two,
                                   _ answers: NewTabKeySessionWalkTests.HeldAnswers) async throws -> (real: String, first: AgentTabKey) {
        let tabs = services.agentTabs
        let store = services.machines.local.store
        let model = pane.pane
        let workspace = try #require(store.workspace(containing: model.handle), "setup: the keys' pane has no workspace")
        let holder = workspace.screens.first(where: { screen in screen.panes.contains(where: { $0.handle == model.handle }) })
        let screen = try #require(holder, "setup: the keys' pane has no screen")
        try #require(answers.asks.count == 2, "setup: \(answers.asks.count) creations wait after the 2 New Tab keys, want 2")
        let ask = answers.asks[0]
        let sequence = max(store.appliedSequence, store.snapshotBarrier) + 1
        let surface = SurfaceID(rawValue: 5_000_000)
        var entity = TabSnapshot(surface: surface, tabResourceID: ResourceID(rawValue: "tab_made_in_the_hold"), kind: .conversation,
                                 title: "about:blank", browserRenderer: "frontend")
        entity.conversation = ConversationTabRef(agentSession: ask.record)
        let added = TabDelta(workspace: workspace.handle, screen: screen.handle, pane: ask.pane, surface: surface, index: nil,
                             entity: entity, clientTransactionID: ask.transaction)
        store.apply(batch: [DaemonEventEnvelope(sequence: sequence, event: .tabAdded(added))])
        let tab = try #require(store.tab(surface: surface), "setup: the store has no tab for the daemon's event")
        let known = tabs.aliases.onlyKey(ofTab: made.tab1).flatMap { tabs.aliases[$0] == tab.id ? $0 : nil }
        let first = try #require(known, "setup: the app did not know the first id of the tab directly after the daemon's event")
        let settled: UInt64? = sequence
        answers.answer(0, with: (created: AgentTabCreated(key: tab.id, surface: surface), sequence: settled))
        await LargeSessionWindowFixture.drainMain()
        let real = tab.id
        try #require(real != made.tab1 && strip.contains(real) && !strip.contains(made.tab1),
                     "setup: after the daemon's answer the pane does not list the first new tab by the id of the daemon's tab (\(real)): its tabs \(strip), the first id \(made.tab1)")
        try #require(tabs.isNewTabPage(real), "setup: the first new tab is no New Tab page after the daemon made it: the row then proves nothing")
        try #require(pane.currentTabKey == made.tab2, "setup: the pane does not show the second new tab after the daemon's answer")
        try #require(input.isHolding(in: window),
                     "setup: the key hold of the second new tab ended at the daemon's answer for the first new tab. The hold's log ends: \(holdLog)")
        return (real, first)
    }

    /// Makes the case of row 10 sure. `known`: the app knows `real` by the first id of its tab (`first`), else it
    /// does not. Returns true when the row changed by hand what the app knew.
    func makesSure(known: Bool, first: AgentTabKey, of real: String) -> Bool {
        let tabs = services.agentTabs
        let knows = tabs.resolve(first.key) == real
        if known, !knows { tabs.aliases[first] = real }
        if !known, knows { _ = tabs.aliases.removeValue(forKey: first) }
        return known != knows
    }
}
