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
/// The rule of these rows: a New Tab tab that a pane shows and that has no page view takes the page view of an
/// untouched New Tab tab that no pane shows. So a tab that is shown never waits for a new page view while such
/// a page view is there, and a hold makes none.
///
/// - Row 1: a hold of New Tab keys makes no page view, and the tabs have no more page views than before it.
/// - Row 2: a hold and then a walk back over its tabs make no page view, and each tab has a page view when the
///   pane shows it.
/// - Row 3: a hold of the Close Tab key over the tabs of a hold: the pane shows the same page view after each
///   close, each close takes the tab that the pane showed, and no page view is made.
/// - Row 4, what must stay: a New Tab tab and a terminal tab shown in turn make no page view, and the New Tab tab
///   keeps its page view.
/// - Row 5: a New Tab key from a terminal tab, while a New Tab tab that the pane does not show has an untouched
///   page view: the new tab takes that page view, and none is made.
/// - Row 6: a New Tab key that the focused page's view saw first does not make that page a touched one: the new
///   tab has the page view that the pane showed before the key.
/// - Row 7, what must stay: a New Tab tab in whose page the person typed a letter or clicked keeps its page view
///   at the next New Tab key.
/// - Row 8: a hover over a New Tab tab with no page view makes none. The hover load takes each chat tab that has a
///   record of its host (`TabModel.loadsAheadOnHover`), and a New Tab tab has that record with no chat in it, so
///   the pane's hover load asks the store for the tab's view (`PaneController.loadOnHover`).
/// - Rows 9, 10 and 12 (a split, a terminal of another folder, a hold of New Workspace keys) are
///   `NewTabHoldOtherScreensTests`; row 11 (the tabs that a store restored) is `NewTabPagesOfRestoredTabsTests`.
/// - Row 13 (several untouched page views in one pane: the new tab takes the one that its pane leaves) is in
///   `NewTabHoldMovesItsPageTests+OwnPage.swift`.
/// - Row 14 (the Close Tab key after a hold, read in the key's own turn, with the last tab's creation answered and
///   not answered) is in `NewTabHoldMovesItsPageTests+CloseKey.swift`.
///
/// The app is the package's own, with a daemon of this tree and an empty pool of pages made ahead, so each new
/// page view here is a cold one (the setup of `NewTabPageAtItsFrameTests`). That setup's pane starts with a New
/// Tab page of its own, so each row starts with one New Tab key: the tab that the pane shows then is one that a
/// key made, with a page view, whatever the pane had before. A frame is the app's own: a row waits for one by an
/// event. Each key is the New Tab action's own call (`NewTabPage.open`), each tab switch is the pane's own call
/// (`select`), each close is the pane's own call (`close`), the hover of row 8 is the pane's own call
/// (`loadOnHover`, which the hover's dwell calls). Rows 1 to 5 and 8 send no key event. Row 6 sends its New
/// Tab key as a key-down event: first to the page's view (`AgentPaneView.judge`, which the app's event monitor
/// calls), then through the key router (`KeyRouter.interceptKeyDown`). Row 7 sends its letter or its click to the
/// page's view only.
///
/// The measure is the count of distinct page views (`Views`), not the store's count of built pages: that count
/// has a page that a tab adopts too.
///
/// Limits. The package's tests have no Chromium host, so each page view is a WebKit one. A row that makes more
/// than 2 page views in its hold stops the hold there: a hold that makes a page view for each key must not make
/// 94 web views on the test's Mac. The rows read the count of page views and which view a tab has; they do not
/// read what a page draws.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabHoldMovesItsPageTests {
    /// The distinct page views that the pane's New Tab tabs had since the row's start. It keeps each view, so a
    /// closed view's place in memory is not counted as a new one.
    @MainActor final class Views {
        private var seen: [AgentPaneView] = []
        var count: Int { seen.count }
        /// The reads at which the store's index of its New Tab page views (`AgentTabMap.marked`, which the pull reads
        /// in place of each view) did not agree with a walk over each view. Each row wants none (`row`).
        private(set) var indexFaults: [String] = []
        private var reads = 0

        func note(_ view: AgentPaneView) {
            if !seen.contains(where: { $0 === view }) { seen.append(view) }
        }

        /// The page views that the pane's New Tab tabs have now. Each read compares the store's index with a walk.
        func read(_ pane: PaneController, _ services: AppServices) -> [AgentPaneView] {
            let now = NewTabHoldMovesItsPageTests.newTabs(of: pane, services).compactMap { services.agentTabs.existingView($0) }
            now.forEach(note)
            reads += 1
            let all = services.agentTabs.views
            let walked = Set(all.entries.filter { $0.value.model.newTab != nil }.map(\.key))
            let missing = walked.subtracting(all.marked).count, dead = all.marked.filter { all[$0] == nil }.count
            if missing + dead > 0 {
                indexFaults.append("read \(reads): \(missing) New Tab page views are not in the index, \(dead) keys of the index have no view")
            }
            return now
        }

        /// The page views of this row that no tab has now: the store let go of each (a close of the view, or its
        /// return to the pool of pages made ahead).
        func gone(_ services: AppServices) -> Int {
            let held = services.agentTabs.views.values
            return seen.filter { view in !held.contains { $0 === view } }.count
        }
    }

    /// The pane's tabs that are New Tab pages, in the strip's order, by the keys that they have now (the store can
    /// give a tab a new key when the daemon answers its creation).
    static func newTabs(of pane: PaneController, _ services: AppServices) -> [String] {
        pane.orderedIDs.map(\.rawValue).filter { services.agentTabs.isNewTabPage($0) }
    }

    /// Asks the window for its made-ahead workspace (the workspace of the next New Workspace key,
    /// `WindowController.reservedContent`) and waits until the window has it. The window makes it as idle work after
    /// it shows a workspace, with a page view for its New Tab page, at a time that a row does not fix. A row asks
    /// for it before its count, so that page view is made before the count and not in it. The wait has a deadline,
    /// and the setup fails when the window has no such workspace then, or when that workspace's tab has no page view.
    /// It prints the page views that the store built in the wait, and how many of them were for that tab.
    static func makesItsWorkspaceAhead(_ controller: WindowController, _ services: AppServices, row: String) async throws {
        let tabs = services.agentTabs, store = services.daemon.store, built = Built()
        let had = controller.reservedContent.ready != nil, wired = tabs.onPageBuilt
        tabs.onPageBuilt = { key in
            built.keys.append(key)
            wired?(key)
        }
        defer { tabs.onPageBuilt = wired }
        controller.reservedContent.fill()
        try await PasswordManagerRouteTests.until({ controller.reservedContent.ready != nil && store.reservedWorkspace != nil },
                                                  within: .seconds(10), report: { "setup: the window made no workspace ahead" })
        let ahead = try #require(store.reservedWorkspace?.tabKey, "setup: the store has no made-ahead workspace after the wait")
        let forIt = built.keys.filter { $0 == ahead }.count, has = tabs.existingView(ahead) != nil
        print("""
            NewTabHoldMovesItsPageTests: setup of \(row): the window \(had ? "had" : "did not have") its made-ahead workspace before the \
            row asked for it; the store built \(built.keys.count) page views in the wait, \(forIt) of them for the tab of the \
            made-ahead workspace; that tab has \(has ? "a page view" : "no page view") before the row's count
            """)
        try #require(has, "setup: the tab of the window's made-ahead workspace has no page view before the row's count")
    }

    /// The keys of the page views that the store built in a wait of the setup (`makesItsWorkspaceAhead`).
    @MainActor final class Built {
        var keys: [String] = []
    }

    /// The setup of each row: an empty pool, the window's made-ahead workspace (`makesItsWorkspaceAhead`: else its
    /// page view is made in the count of a row at one run and not at the next), each page view that the store builds
    /// or adopts noted, and ONE New Tab key with the wait for its page view (`waitsForItsPage`). `body` gets the count
    /// of page views that the pane's New Tab tabs have after that key.
    static func row(_ install: String,
                    _ body: (AppServices, PaneController, Views, Int) async throws -> Void) async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool(install) { services, _, pane, _ in
            let tabs = services.agentTabs, views = Views()
            let window = try #require(services.windows.active, "setup: no window")
            try await makesItsWorkspaceAhead(window, services, row: install)
            let wired = tabs.onPageBuilt
            tabs.onPageBuilt = { key in
                if let view = tabs.existingView(key) { views.note(view) }
                wired?(key)
            }
            defer { tabs.onPageBuilt = wired }
            _ = views.read(pane, services)
            let pressed = ContinuousClock.now
            NewTabPage.open(in: pane, seed: nil)
            try await waitsForItsPage(pane, services, row: install, since: pressed)
            try await body(services, pane, views, views.read(pane, services).count)
            _ = views.read(pane, services)
            #expect(views.indexFaults.isEmpty,
                    "the store's index of its New Tab page views did not agree with a walk over each view at \(views.indexFaults.count) reads of the row: \(views.indexFaults.prefix(3))")
        }
    }

    /// The setup's wait for the page view of the row's own New Tab tab: frames of the app until the tab that the pane
    /// shows has a page view, 10 seconds at most. A New Tab key with no warm page gets its page view at the key's
    /// frame. One setup of 8 in one run had none at that frame. The cause by a read of the code, not proved by a run:
    /// the daemon's answer for the creation came before that frame, the app then asks the store for the daemon's key
    /// (the alias of the shown key), and the store lists that key only when the daemon's tree brings it. The rows
    /// count after the wait, so no row wants a page view at the key's frame for a key with that order.
    ///
    /// Prints ONE line that starts `SETUP WAIT:`: the frames and the time from the key to the page view, and what the
    /// app had at the first frame: the shown key, the key that the alias gives for it (`none`: no alias), and if the
    /// store listed that key (with no alias: the shown key). A line with more than 1 frame, an alias and `false` is
    /// that order by a run.
    static func waitsForItsPage(_ pane: PaneController, _ services: AppServices, row: String,
                                since key: ContinuousClock.Instant) async throws {
        let tabs = services.agentTabs
        var frames = 0, first = "the pane showed no tab"
        repeat {
            await NewTabPageAtItsFrameTests.frame(services)
            frames += 1
            if frames == 1, let shown = pane.currentTabKey {
                let alias = tabs.resolve(shown), listed = services.daemon.store.tab(idOrResource: alias) != nil
                first = "the shown key \(shown), the alias's key \(alias == shown ? "none" : alias), the store lists it: \(listed)"
            }
        } while pane.currentTabKey.flatMap({ tabs.existingView($0) }) == nil && ContinuousClock.now - key < .seconds(10)
        let ms = Int((ContinuousClock.now - key) / .milliseconds(1))
        print("SETUP WAIT: NewTabHoldMovesItsPageTests \(row): \(frames) frames and \(ms) ms from the row's own New Tab key to its page view; at the first frame: \(first)")
        let shown = try #require(pane.currentTabKey, "setup: the pane shows no tab after the row's own New Tab key")
        try #require(tabs.isNewTabPage(shown), "setup: the pane shows no New Tab tab after the row's own New Tab key")
        try #require(tabs.existingView(shown) != nil, "setup: the row's own New Tab tab has no page view \(frames) frames after its key")
    }

    /// A hold of `keys` New Tab keys with a frame of the app after each. It stops after the key that made the third
    /// page view of the hold. Returns the keys pressed, the most page views that the pane's New Tab tabs had at one
    /// time, and the count of page views made.
    static func hold(_ keys: Int, in pane: PaneController, _ services: AppServices, _ views: Views) async -> (pressed: Int, most: Int, made: Int) {
        let before = views.count
        var pressed = 0, most = 0
        for _ in 0..<keys {
            NewTabPage.open(in: pane, seed: nil)
            await NewTabPageAtItsFrameTests.frame(services)
            pressed += 1
            most = max(most, views.read(pane, services).count)
            if views.count - before > 2 { break }
        }
        return (pressed, most, views.count - before)
    }

    /// Shows the pane's tab `key` and waits for one frame of the app.
    static func show(_ key: String, in pane: PaneController, _ services: AppServices) async throws {
        let id = try #require(pane.orderedIDs.first { $0.rawValue == key }, "setup: the tab \(key) is not in the strip")
        pane.select(id)
        await NewTabPageAtItsFrameTests.frame(services)
        try #require(pane.currentTabKey == key, "setup: the pane does not show the tab that the row selected, one frame after the select")
    }

    /// Opens a terminal tab in the pane (in the folder `cwd`, when the row gives one) and waits until the daemon made
    /// it and the pane shows it. Returns its key.
    static func terminalTab(in pane: PaneController, _ services: AppServices, cwd: String? = nil) async throws -> String {
        pane.newTerminalTab(cwd: cwd)
        try await PasswordManagerRouteTests.until({
            pane.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
        }, report: { "setup: the daemon made no terminal tab in the pane" })
        let terminal = try #require(pane.pane.tabs.first { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }?.id)
        try await PasswordManagerRouteTests.until({ pane.orderedIDs.contains { $0.rawValue == terminal } },
                                                  report: { "setup: the terminal tab is not in the pane's strip" })
        try await show(terminal, in: pane, services)
        try #require(!services.agentTabs.isNewTabPage(terminal), "setup: the terminal tab is a New Tab page")
        return terminal
    }

    /// Row 1. A hold of 94 New Tab keys, with a frame after each key as a hold at the key repeat rate has. Want: no
    /// page view is made in the hold, the pane's New Tab tabs have no more page views at a frame than before the
    /// hold, and the tab that the pane shows after the hold has a page view.
    @Test(arguments: [94]) func aHoldOfNewTabKeysMakesNoPageView(keys: Int) async throws {
        try await Self.row("cn-hold-moves-page-hold") { services, pane, views, atStart in
            let held = await Self.hold(keys, in: pane, services, views)
            print("""
                NewTabHoldMovesItsPageTests: row 1, a hold of \(keys) New Tab keys: \(held.pressed) keys pressed, \(held.made) page \
                views made in the hold; the pane's New Tab tabs had \(atStart) page views before the hold and \(held.most) at one \
                time at most in it
                """)
            #expect(held.pressed == keys,
                    "the hold stopped after key \(held.pressed) of \(keys): \(held.made) page views were made by then, want 0 for the whole hold")
            #expect(held.made == 0, "\(held.made) page views were made in a hold of \(held.pressed) New Tab keys, want 0")
            #expect(held.most <= atStart,
                    "the pane's New Tab tabs had \(held.most) page views at one time in the hold, \(atStart) before it: want no more")
            let shown = try #require(pane.currentTabKey, "the pane shows no tab after the hold")
            let page = services.agentTabs.existingView(shown)
            #expect(page != nil, "the tab that the pane shows after the hold has no page view")
            // The view that went from tab to tab is in the pane's window and not hidden: the pane shows it, it does not only have it.
            let inThePane = page.map { $0.window != nil && $0.window === pane.view.window && !$0.isHiddenOrHasHiddenAncestor } ?? false
            #expect(inThePane, "the page view of the tab that the pane shows after the hold is hidden or in no window of the pane")
        }
    }

    /// Row 2. A hold of 6 keys, then the person goes back over the 6 tabs before the last one, one tab at each
    /// frame. Want: the hold and the walk make no page view, the tab that the pane shows has a page view at each
    /// step, and the tabs have no more page views at a step than before the hold.
    @Test func aHoldAndAWalkBackOverItsTabsMakeNoPageView() async throws {
        try await Self.row("cn-hold-moves-page-walk") { services, pane, views, atStart in
            let before = Self.newTabs(of: pane, services).count
            let held = await Self.hold(6, in: pane, services, views)
            let count = Self.newTabs(of: pane, services).count
            try #require(count == before + held.pressed, "setup: the pane has \(count) New Tab tabs after \(held.pressed) keys, \(before) before them")
            try #require(pane.currentTabKey == Self.newTabs(of: pane, services).last, "setup: the tab of the last key is not the last New Tab tab of the strip")
            let madeBeforeTheWalk = views.count
            var most = 0, steps = 0, withNoPage = 0
            // The tabs of the hold but its last, then the tab of the row's own key: one step for each key of the hold.
            for step in 1...held.pressed {
                // The key that the tab has now: a tab can get a new key between two steps.
                let key = Self.newTabs(of: pane, services)[count - 1 - step]
                try await Self.show(key, in: pane, services)
                steps += 1
                most = max(most, views.read(pane, services).count)
                if services.agentTabs.existingView(key) == nil { withNoPage += 1 }
            }
            let inTheWalk = views.count - madeBeforeTheWalk
            print("""
                NewTabHoldMovesItsPageTests: row 2, a hold of \(held.pressed) keys and a walk back of \(steps) steps: \(held.made) \
                page views made in the hold, \(inTheWalk) in the walk; the tabs had \(atStart) page views before the hold, \
                \(held.most) at most in the hold, \(most) at most in the walk; \(withNoPage) steps showed a tab with no page view
                """)
            #expect(held.made + inTheWalk == 0,
                    "the hold made \(held.made) page views and the walk back made \(inTheWalk), want 0 over the hold and the walk")
            #expect(withNoPage == 0, "\(withNoPage) of \(steps) steps showed a tab with no page view, one frame after the pane showed it")
            #expect(max(held.most, most) <= atStart,
                    "the pane's New Tab tabs had \(max(held.most, most)) page views at one time, \(atStart) before the hold: want no more")
        }
    }

    /// Row 3. A hold of 94 New Tab keys, then a hold of the Close Tab key over those tabs, with a frame after each
    /// close. Want: each close takes the tab that the pane showed; after each close the pane shows the page view
    /// that it showed before the close (the page goes to the tab that is shown next: no page view is closed while
    /// a tab of the hold is there); and no page view is made at a show.
    @Test(arguments: [94]) func aCloseHoldOverTheTabsOfAHoldKeepsThePageView(keys: Int) async throws {
        try await Self.row("cn-hold-moves-page-close") { services, pane, views, _ in
            let tabs = services.agentTabs
            let held = await Self.hold(keys, in: pane, services, views)
            let madeBeforeTheCloses = views.count
            var closes = 0, outOfOrder = 0, otherPage = 0, noPage = 0
            // One close for each key of the hold: the last close shows the tab of the row's own key.
            for _ in 0..<held.pressed {
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
                _ = views.read(pane, services)
            }
            let inTheCloses = views.count - madeBeforeTheCloses
            print("""
                NewTabHoldMovesItsPageTests: row 3, a close hold over the tabs of a hold of \(held.pressed) keys: \(closes) closes; \
                \(outOfOrder) closes did not take the shown tab; after \(otherPage) closes the pane showed another page view, \
                after \(noPage) closes a tab with no page view; \(held.made) page views made in the hold, \(inTheCloses) in the \
                close hold
                """)
            #expect(held.pressed == keys, "the hold stopped after key \(held.pressed) of \(keys): \(held.made) page views were made by then")
            #expect(outOfOrder == 0, "\(outOfOrder) of \(closes) closes did not take the tab that the pane showed, and only that tab")
            #expect(otherPage == 0, "after \(otherPage) of \(closes) closes the pane showed another page view than before the close: the page did not go to the tab that is shown next")
            #expect(noPage == 0, "after \(noPage) of \(closes) closes the pane showed a tab with no page view, one frame after the close")
            #expect(inTheCloses == 0, "the close hold made \(inTheCloses) page views, want 0")
        }
    }

    /// Row 4, what must stay. A New Tab tab and a terminal tab. The person shows the 2 tabs in turn 20 times, one
    /// tab at each frame. Want: no page view is made, and the New Tab tab has the same page view each time that the
    /// pane shows it. The row counts each round by itself: a round that makes a page view, or in which the store lets
    /// go of one, is a fault also when the next round gives it back.
    @Test func aNewTabTabAndATerminalTabShownInTurnMakeNoPageView() async throws {
        try await Self.row("cn-hold-moves-page-turns") { services, pane, views, _ in
            let tabs = services.agentTabs
            let index = Self.newTabs(of: pane, services).count - 1
            let page = try #require(pane.currentTabKey.flatMap { tabs.existingView($0) }, "setup: the New Tab tab has no page view")
            let terminal = try await Self.terminalTab(in: pane, services)
            let made = views.count
            var withNoPage = 0, withAnotherPage = 0
            // For each round: the page views made in it, and the page views that the store let go of in it.
            var rounds: [(made: Int, gone: Int)] = []
            for _ in 0..<20 {
                let (madeBefore, goneBefore) = (views.count, views.gone(services))
                let newTab = try #require(Self.newTabs(of: pane, services).dropFirst(index).first, "setup: the pane lost its New Tab tab")
                try await Self.show(newTab, in: pane, services)
                let now = tabs.existingView(newTab)
                if now == nil { withNoPage += 1 } else if now !== page { withAnotherPage += 1 }
                _ = views.read(pane, services)
                try await Self.show(terminal, in: pane, services)
                _ = views.read(pane, services)
                rounds.append((views.count - madeBefore, views.gone(services) - goneBefore))
            }
            let costly = rounds.enumerated().filter { $0.element.made + $0.element.gone > 0 }.map { "round \($0.offset + 1): \($0.element.made) made, \($0.element.gone) let go" }
            print("""
                NewTabHoldMovesItsPageTests: row 4, a New Tab tab and a terminal tab shown in turn 20 times: \(views.count - made) \
                page views made in the turns; \(withNoPage) times the New Tab tab had no page view when the pane showed it, \
                \(withAnotherPage) times another page view; rounds that made a page view or let go of one: \(costly)
                """)
            #expect(costly.isEmpty, "\(costly.count) of 20 rounds made a page view or let go of one, want 0 in each round: \(costly)")
            #expect(views.count == made, "the 20 turns made \(views.count - made) page views, want 0")
            #expect(withNoPage == 0, "\(withNoPage) of 20 times the New Tab tab had no page view, one frame after the pane showed it")
            #expect(withAnotherPage == 0, "\(withAnotherPage) of 20 times the New Tab tab had another page view than before the turns")
        }
    }

    /// Row 5. The pane has a New Tab tab with an untouched page view and shows a terminal tab. Then a New Tab key.
    /// Want: the new tab has a page view at its frame and no page view is made: a tab that the pane shows does not
    /// wait for a new page view while an untouched one that no pane shows is there.
    @Test func aNewTabKeyFromATerminalTabTakesTheHiddenUntouchedPageView() async throws {
        try await Self.row("cn-hold-moves-page-pull") { services, pane, views, atStart in
            let tabs = services.agentTabs
            _ = try await Self.terminalTab(in: pane, services)
            let made = views.count
            NewTabPage.open(in: pane, seed: nil)
            await NewTabPageAtItsFrameTests.frame(services)
            let shown = try #require(pane.currentTabKey, "setup: the pane shows no tab after the New Tab key")
            try #require(tabs.isNewTabPage(shown), "setup: the pane shows no New Tab tab after the New Tab key")
            let now = views.read(pane, services).count
            print("""
                NewTabHoldMovesItsPageTests: row 5, a New Tab key from a terminal tab beside a hidden untouched New Tab tab: \
                \(views.count - made) page views made; the pane's New Tab tabs had \(atStart) page views before the key and \
                \(now) after it
                """)
            #expect(tabs.existingView(shown) != nil, "the new tab has no page view, one frame after its key")
            #expect(views.count == made, "the New Tab key made \(views.count - made) page views, want 0: an untouched page view that no pane showed was there")
            #expect(now <= atStart, "the pane's New Tab tabs have \(now) page views after the key, \(atStart) before it: want no more")
        }
    }

    /// Gives the web view of `page` the keyboard, as it has after the page's report or after a click in the page.
    static func keyboard(to page: AgentPaneView, in pane: PaneController) throws -> NSWindow {
        let window = try #require(pane.view.window, "setup: the pane's view is in no window")
        try #require(window.makeFirstResponder(page.webView) && window.firstResponder === page.webView,
                     "setup: the web view of the page did not take the keyboard")
        return window
    }

    /// A key-down event of the row for `window`.
    static func keyDown(_ characters: String, code: UInt16, command: Bool, in window: NSWindow) throws -> NSEvent {
        let made = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        return try #require(made, "setup: no key event could be made")
    }

    /// Row 6. The page of the shown New Tab tab has the keyboard, and the person presses the New Tab key. The view
    /// of that page sees the key-down first (the app's event monitor calls `judge` before AppKit gives the event
    /// on), then the key router takes the key and opens the tab. Want: that key does not make the page a touched
    /// one: the new tab has the page view that the pane showed before the key, and no page view is made. A hold
    /// with the page focused is this case at each key.
    @Test func aNewTabKeyThatThePagesViewSawLeavesThePageUntouched() async throws {
        try await Self.row("cn-hold-moves-page-mark-key") { services, pane, views, _ in
            let tabs = services.agentTabs
            let first = try #require(pane.currentTabKey, "setup: the pane shows no tab")
            let page = try #require(tabs.existingView(first), "setup: the shown New Tab tab has no page view")
            let window = try Self.keyboard(to: page, in: pane)
            let made = views.count, strip = pane.orderedIDs.count
            let event = try Self.keyDown("t", code: 17, command: true, in: window)
            page.judge(event, eventWindow: window)
            let router = services.keyRouter
            let took = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
            try #require(took, "setup: the key router passed the New Tab key on")
            try #require(pane.orderedIDs.count == strip + 1, "setup: the New Tab key added \(pane.orderedIDs.count - strip) tabs to the strip, want 1")
            await NewTabPageAtItsFrameTests.frame(services)
            let shown = try #require(pane.currentTabKey, "setup: the pane shows no tab after the New Tab key")
            try #require(shown != first && tabs.isNewTabPage(shown), "setup: the pane does not show the new tab, one frame after its key")
            let now = tabs.existingView(shown)
            _ = views.read(pane, services)
            print("""
                NewTabHoldMovesItsPageTests: row 6, a New Tab key that the focused page's view saw first: \(views.count - made) \
                page views made; the new tab has the page view that the pane showed before the key: \(now === page); the \
                new tab has a page view: \(now != nil)
                """)
            #expect(now === page, "the new tab does not have the page view that the pane showed before the key: the New Tab key made that page a touched one, or no page goes to the tab that is shown next")
            #expect(views.count == made, "the New Tab key made \(views.count - made) page views, want 0")
        }
    }

    /// Row 7, what must stay. The person types a letter in the shown New Tab tab's page, or clicks in it: the view
    /// of that page sees the event first (`judge`), as in row 6. Then a New Tab key. Want: the tab that the person
    /// touched keeps its page view, and the new tab has another one or none: a page that the person touched never
    /// goes to another tab. The row sends the event to the view only: no page gets it, so no page reports it.
    @Test(arguments: ["a letter", "a click"]) func aNewTabTabThatThePersonTouchedKeepsItsPageView(touch: String) async throws {
        try await Self.row("cn-hold-moves-page-mark-\(touch == "a letter" ? "letter" : "click")") { services, pane, views, _ in
            let tabs = services.agentTabs
            let index = Self.newTabs(of: pane, services).count - 1
            let first = try #require(pane.currentTabKey, "setup: the pane shows no tab")
            let page = try #require(tabs.existingView(first), "setup: the shown New Tab tab has no page view")
            let window = try Self.keyboard(to: page, in: pane)
            let event: NSEvent
            if touch == "a letter" {
                event = try Self.keyDown("a", code: 0, command: false, in: window)
            } else {
                let middle = page.webView.convert(CGPoint(x: page.webView.bounds.midX, y: page.webView.bounds.midY), to: nil)
                let click = NSEvent.mouseEvent(with: .leftMouseDown, location: middle, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                event = try #require(click, "setup: no mouse event could be made")
            }
            page.judge(event, eventWindow: window)
            let made = views.count
            NewTabPage.open(in: pane, seed: nil)
            await NewTabPageAtItsFrameTests.frame(services)
            let shown = try #require(pane.currentTabKey, "setup: the pane shows no tab after the New Tab key")
            try #require(shown != first && tabs.isNewTabPage(shown), "setup: the pane does not show the new tab, one frame after its key")
            let touched = try #require(Self.newTabs(of: pane, services).dropFirst(index).first, "setup: the pane lost the tab that the person touched")
            let kept = tabs.existingView(touched), now = tabs.existingView(shown)
            _ = views.read(pane, services)
            print("""
                NewTabHoldMovesItsPageTests: row 7, \(touch) in a New Tab page, then a New Tab key: the touched tab kept its \
                page view: \(kept === page); the new tab has that page view: \(now === page); \(views.count - made) page views \
                made
                """)
            #expect(kept === page, "the New Tab tab that the person touched (\(touch)) does not have its page view after the next New Tab key")
            #expect(now !== page, "the new tab has the page view of the tab that the person touched (\(touch))")
        }
    }

    /// Row 8. 3 New Tab keys in one turn of the main thread: no frame shows the first 2 of their tabs, so those have
    /// no page view. The pointer rests on each of the 2. Want: the hover makes no page view, and the 2 tabs have
    /// none after it: a New Tab tab that the person did not touch gets its page view when a pane shows it, not
    /// before.
    @Test func aHoverOverANewTabTabWithNoPageViewMakesNone() async throws {
        try await Self.row("cn-hold-moves-page-hover") { services, pane, views, _ in
            let tabs = services.agentTabs
            let before = Self.newTabs(of: pane, services).count
            for _ in 0..<3 { NewTabPage.open(in: pane, seed: nil) }
            await NewTabPageAtItsFrameTests.frame(services)
            let count = Self.newTabs(of: pane, services).count
            try #require(count == before + 3, "setup: the pane has \(count) New Tab tabs after 3 keys, \(before) before them")
            _ = views.read(pane, services)
            // The places of the first 2 of the 3 new tabs in the strip's New Tab tabs: a tab's key can change, its place does not.
            let places = [before, before + 1]
            let bare = places.filter { tabs.existingView(Self.newTabs(of: pane, services)[$0]) == nil }
            try #require(bare.count == 2, "setup: \(2 - bare.count) of the first 2 tabs of 3 keys in one turn have a page view: the row needs tabs with none")
            let made = views.count
            for place in bare { pane.loadOnHover(Self.newTabs(of: pane, services)[place]) }
            await NewTabPageAtItsFrameTests.frame(services)
            _ = views.read(pane, services)
            let withPage = bare.filter { tabs.existingView(Self.newTabs(of: pane, services)[$0]) != nil }.count
            print("""
                NewTabHoldMovesItsPageTests: row 8, a hover over 2 New Tab tabs with no page view: \(views.count - made) page \
                views made; \(withPage) of the 2 tabs have a page view after the hover
                """)
            #expect(views.count == made, "the hover made \(views.count - made) page views, want 0")
            #expect(withPage == 0, "\(withPage) of 2 New Tab tabs that no pane shows have a page view after a hover")
        }
    }
}
