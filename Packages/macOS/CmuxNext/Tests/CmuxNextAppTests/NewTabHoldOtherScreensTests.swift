import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// The page view of an untouched New Tab tab goes to the New Tab tab that a pane shows next
/// (`NewTabHoldMovesItsPageTests`). These rows are the cases with more than one pane, more than one folder and more
/// than one workspace: what such a move must not take, and what it must not draw.
///
/// - Row 9: a split from a New Tab page. The pane that the split came from keeps its page view (a pane shows it),
///   the split's pane has its own, and a hold of New Tab keys in the split's pane makes one page view at most and
///   takes none from the first pane.
/// - Row 10: a New Tab key from a terminal tab of another folder. The new tab's page view has the new tab's own
///   folder and its own key-hold token, and the key makes one page view at most.
/// - Row 12: a hold of 20 New Workspace keys. Each key's workspace opens on a New Tab page, and the workspace
///   before it goes out of view with an untouched New Tab page. The hold makes one page view at most.
///
/// (Row 11, the tabs that a store restored, is `NewTabPagesOfRestoredTabsTests`: it needs no daemon.)
///
/// The app is the package's own, with a daemon of this tree and an empty pool of pages made ahead (the setup of
/// `NewTabPageAtItsFrameTests`). Rows 9 and 10 start as the rows of `NewTabHoldMovesItsPageTests` do, after one New
/// Tab key. The split is the New Tab page's own call (`NewTabPage.split`), each New Tab key is the action's own call
/// (`NewTabPage.open`), each New Workspace key is the action itself (`newTab` in the registry).
///
/// Limits. Each page view is a WebKit one (the package's tests have no Chromium host). A hold that made 3 page
/// views stops there. The rows read which view a tab has and the context that the view's model has; they do not
/// read what a page draws. Row 12 does not stop the window's own work between two keys: the page view that the
/// window makes ahead for the next New Workspace key is one of the page views that the row counts.
///
/// The window makes a workspace ahead for the next New Workspace key as idle work, with a page view for its New Tab
/// page, at a time that a row does not fix. Each row asks the window for it before its count (the shared setup of
/// `NewTabHoldMovesItsPageTests.row`, and row 12 in its own setup: `makesItsWorkspaceAhead`). Row 9 wants no page
/// view for that workspace after the wait: the window has it before the split. Rows 9 and 12 print each call of the
/// store's build hook with the place of its tab (`Builds`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabHoldOtherScreensTests {
    typealias Moves = NewTabHoldMovesItsPageTests

    /// Whether the page view of the New Tab tab `key` has that tab's own context: its folder and its key-hold token.
    static func hasItsOwnContext(_ key: String, _ tabs: AgentTabStore) -> Bool {
        guard let own = tabs.newTabPages[tabs.tabKey(key)]?.page, let drawn = tabs.existingView(key)?.model.newTab else { return false }
        return drawn.cwd == own.cwd && drawn.inputToken == own.inputToken
    }

    /// The calls of the tab store's build hook in a row (`AgentTabStore.onPageBuilt`: the store built a page view, or
    /// a tab adopted one). Each call has its tab's key, the part of the row that it came in, and whether it came with
    /// a page view that the store did not have at the row's start or at a call before. A row prints the calls with the
    /// place of each call's tab, so its run says for which tab each page view was made.
    ///
    /// The place is read at the call and at the turn after it, not at the row's end: the store gives a tab a new key
    /// when the daemon answers its creation, and it reserves the made-ahead workspace after it built that workspace's
    /// page view, in the same turn (`AgentTabStore.reserveWorkspace`).
    @MainActor final class Builds {
        typealias Call = (key: String, part: String, new: Bool)
        static let madeAhead = "the tab of the window's made-ahead workspace"
        var part = "the setup"
        private(set) var calls: [Call] = []
        private var places: [Int: String] = [:]
        private var askers: [Int: String] = [:]
        private var seen: [AgentPaneView]
        private let services: AppServices
        private let place: @MainActor (String) -> String?

        /// `place`: the row's name for the place of a tab at this time (a pane, a workspace), nil when it has none.
        init(_ services: AppServices, place: @escaping @MainActor (String) -> String?) {
            self.services = services
            self.place = place
            seen = services.agentTabs.views.values.map { $0 }
        }

        func note(_ key: String) {
            let view = services.agentTabs.existingView(key)
            let new = view.map { view in !seen.contains { $0 === view } } ?? false
            if let view, new { seen.append(view) }
            let index = calls.count
            calls.append((key: key, part: part, new: new))
            places[index] = place(key)
            if new { askers[index] = PageMoves.asker() } // who asked for a new page view, by the call stack
            Task { @MainActor [weak self] in self?.settle(index, key) }
        }

        private func settle(_ index: Int, _ key: String) {
            if services.daemon.store.reservedWorkspace?.tabKey == key {
                places[index] = Self.madeAhead
            } else if places[index] == nil {
                places[index] = place(key)
            }
        }

        /// The calls in words, in their order.
        var listed: [String] {
            calls.enumerated().map { index, call in
                let words = "\(call.part): \(call.new ? "a new page view" : "a page view that the store had") for \(places[index] ?? "a tab that the row has no name for")"
                return words + (askers[index].map { ", asked by \($0)" } ?? "")
            }
        }

        /// The new page views of `part` that were for the window's made-ahead workspace.
        func ahead(in part: String) -> Int {
            calls.enumerated().filter { index, call in call.part == part && call.new && places[index] == Self.madeAhead }.count
        }

        /// The new page views whose tab the row has no name for.
        var notNamed: Int { calls.enumerated().filter { index, call in call.new && places[index] == nil }.count }
    }

    /// Whether `pane` has the tab `key` in its strip, or shows it, by the key or by the store's name of it now.
    static func has(_ pane: PaneController, _ key: String, _ tabs: AgentTabStore) -> Bool {
        let now = tabs.resolve(key)
        return pane.currentTabKey == key || pane.currentTabKey == now || pane.orderedIDs.contains { $0.rawValue == key || $0.rawValue == now }
    }

    /// Row 9. The pane shows an untouched New Tab tab, and the person splits it: the split's pane opens on a New Tab
    /// page with a list of the workspace's open tabs. Then a hold of 3 New Tab keys in the split's pane. Want: the
    /// first pane still shows its tab with the page view that it had; the split's pane has another page view; the
    /// split makes one page view at most and the hold one at most; and after the hold the first pane's tab still has
    /// its page view: a page view that a pane shows is never taken.
    @Test func aSplitFromANewTabPageLeavesThePaneItsPageView() async throws {
        try await Moves.row("cn-hold-other-screens-split") { services, pane, views, _ in
            let tabs = services.agentTabs
            let first = try #require(pane.currentTabKey, "setup: the pane shows no tab")
            let page = try #require(tabs.existingView(first), "setup: the shown New Tab tab has no page view")
            let index = Moves.newTabs(of: pane, services).count - 1
            let content = try #require(services.windows.active?.workspaceContent, "setup: the window shows no workspace")
            let window = try #require(pane.view.window, "setup: the pane's view is in no window")
            // The window has its made-ahead workspace from the row's setup (`Moves.row`).
            let builds = Builds(services) { key in
                content.panes.values.first { Self.has($0, key, tabs) }.map { $0 === pane ? "a tab of the first pane" : "a tab of the split's pane" }
            }
            let wired = tabs.onPageBuilt
            tabs.onPageBuilt = { key in
                builds.note(key)
                wired?(key)
            }
            defer { tabs.onPageBuilt = wired }
            builds.part = "the split"
            let made = views.count
            try #require(NewTabPage.split(pane, edge: .right), "setup: the split from the New Tab page did not start")
            // The split's pane, once the daemon made it and it shows a New Tab tab with a page view.
            @MainActor func second() -> PaneController? {
                content.panes.values.first { other in
                    other !== pane && other.pane.handle.rawValue < ProvisionalPane.firstHandle
                        && other.currentTabKey.map { tabs.isNewTabPage($0) && tabs.existingView($0) != nil } == true
                }
            }
            let input = services.keyRouter.newTabInputCoordinator
            try await PasswordManagerRouteTests.until({ second() != nil && !input.isHolding(in: window) },
                                                      report: { "setup: no second pane shows a New Tab tab with a page view after the split, or the split's key hold did not end" })
            let split = try #require(second(), "setup: no second pane")
            let splitTab = try #require(split.currentTabKey, "setup: the split's pane shows no tab")
            let splitPage = tabs.existingView(splitTab)
            _ = views.read(pane, services)
            _ = views.read(split, services)
            let inTheSplit = views.count - made
            let kept = try #require(Moves.newTabs(of: pane, services).dropFirst(index).first, "setup: the first pane lost its New Tab tab")
            let shownAfterTheSplit = pane.currentTabKey == kept, keptAfterTheSplit = tabs.existingView(kept) === page
            var oneScreen = "not known"
            if let mine = tabs.newTabPages[tabs.tabKey(kept)]?.page, let theirs = tabs.newTabPages[tabs.tabKey(splitTab)]?.page {
                oneScreen = "\(mine.drawsSameScreen(as: theirs))"
            }

            let before = Moves.newTabs(of: split, services).count
            builds.part = "the hold"
            let held = await Moves.hold(3, in: split, services, views)
            let after = Moves.newTabs(of: split, services).count
            try #require(after == before + held.pressed, "setup: the split's pane has \(after) New Tab tabs after \(held.pressed) keys, \(before) before them")
            _ = views.read(pane, services)
            let keptNow = try #require(Moves.newTabs(of: pane, services).dropFirst(index).first, "setup: the first pane lost its New Tab tab in the hold")
            let shownInTheSplit = split.currentTabKey
            let own = shownInTheSplit.map { Self.hasItsOwnContext($0, tabs) } ?? false
            // Each build by its tab. The window has its made-ahead workspace before the split, and neither a split nor a New Tab key asks the
            // window for a new one (it is asked when the window shows a workspace or gets the keyboard, and when memory pressure ends): no page view for it.
            let listed = builds.listed
            let aheadInTheSplit = builds.ahead(in: "the split"), aheadInTheHold = builds.ahead(in: "the hold")
            print("""
                NewTabHoldOtherScreensTests: row 9, a split from a New Tab page, then a hold of \(held.pressed) New Tab keys in the \
                split's pane: \(inTheSplit) page views made by the split, \(held.made) in the hold (\(aheadInTheSplit) and \
                \(aheadInTheHold) of them for the window's made-ahead workspace); after the split the first \
                pane showed its tab: \(shownAfterTheSplit), with its page view: \(keptAfterTheSplit); the split's page is the \
                first pane's page view: \(splitPage === page); the 2 tabs' contexts draw one screen: \
                \(oneScreen); after the hold the first pane's tab has its page view: \
                \(tabs.existingView(keptNow) === page); the split's shown tab has its own context: \(own); the store's \
                build hook, each call: \(listed)
                """)
            #expect(shownAfterTheSplit, "the first pane does not show its New Tab tab after the split")
            #expect(keptAfterTheSplit, "the first pane's New Tab tab does not have its page view after the split")
            #expect(splitPage != nil && splitPage !== page, "the split's pane has no page view of its own after the split")
            #expect(inTheSplit <= 1, "the split made \(inTheSplit) page views, want 1 at most. The store's build hook, each call: \(listed)")
            #expect(held.made <= 1,
                    "the hold of \(held.pressed) New Tab keys in the split's pane made \(held.made) page views, want 1 at most. The store's build hook, each call: \(listed)")
            #expect(aheadInTheSplit + aheadInTheHold == 0,
                    """
                    the window made \(aheadInTheSplit) page views for its made-ahead workspace in the split and \(aheadInTheHold) in the \
                    hold, want none: the window had that workspace before the split. The store's build hook, each call: \(listed)
                    """)
            #expect(tabs.existingView(keptNow) === page, "the first pane's New Tab tab does not have its page view after the hold in the split's pane: a page view that a pane shows was taken")
            #expect(own, "the tab that the split's pane shows after the hold has a page view with another tab's folder or token, or none")
        }
    }

    /// Row 10. The pane has an untouched New Tab tab and shows a terminal tab that the row opened in another folder.
    /// Then a New Tab key: the new tab's page has the terminal's folder. Want: the new tab has a page view at its
    /// frame; that page view has the new tab's own folder and its own key-hold token (a page view that came from a
    /// tab of another folder got the new tab's context); and the key makes one page view at most.
    @Test func aNewTabKeyFromATerminalOfAnotherFolderHasThatFolder() async throws {
        try await Moves.row("cn-hold-other-screens-folder") { services, pane, views, _ in
            let tabs = services.agentTabs
            let first = try #require(pane.currentTabKey, "setup: the pane shows no tab")
            let index = Moves.newTabs(of: pane, services).count - 1
            let before = try #require(tabs.newTabPages[tabs.tabKey(first)]?.page, "setup: the shown New Tab tab has no context")
            let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            let terminal = try await Moves.terminalTab(in: pane, services, cwd: folder)
            @MainActor func reported() -> String? { pane.pane.tabs.first { $0.id == terminal }?.cwd }
            try await PasswordManagerRouteTests.until({ reported() != nil }, report: { "setup: the terminal tab has no folder from the daemon" })
            let made = views.count
            NewTabPage.open(in: pane, seed: nil)
            await NewTabPageAtItsFrameTests.frame(services)
            let shown = try #require(pane.currentTabKey, "setup: the pane shows no tab after the New Tab key")
            try #require(shown != terminal && tabs.isNewTabPage(shown), "setup: the pane does not show the new tab, one frame after its key")
            let now = try #require(tabs.newTabPages[tabs.tabKey(shown)]?.page, "setup: the new tab has no context")
            try #require(!before.drawsSameScreen(as: now),
                         "setup: the new tab's context draws the screen of the first New Tab tab (folders \(before.cwd ?? "none") and \(now.cwd ?? "none"), the terminal's \(reported() ?? "none")): the row needs another folder")
            _ = views.read(pane, services)
            let old = Moves.newTabs(of: pane, services).dropFirst(index).first
            let own = Self.hasItsOwnContext(shown, tabs)
            print("""
                NewTabHoldOtherScreensTests: row 10, a New Tab key from a terminal tab of another folder: \(views.count - made) page \
                views made; the first New Tab tab's folder: \(before.cwd ?? "none"), the terminal's: \(reported() ?? "none"), the \
                new tab's: \(now.cwd ?? "none"); the new tab has a page view: \(tabs.existingView(shown) != nil), with its own \
                folder and token: \(own); the first New Tab tab has a page view: \(old.map { tabs.existingView($0) != nil } ?? false)
                """)
            #expect(tabs.existingView(shown) != nil, "the new tab has no page view, one frame after its key")
            #expect(own, "the new tab's page view has another tab's folder or token: a page view of another folder was given to it as it was")
            #expect(views.count - made <= 1, "the New Tab key made \(views.count - made) page views, want 1 at most")
        }
    }

    /// Row 12. One New Workspace key, then a hold of 20, with a frame of the app after each key. Each key's
    /// workspace opens on a New Tab page; the workspace before it goes out of view, and its New Tab page is one that
    /// the person did not touch. Want: the hold makes one page view at most (the page view of the workspace that goes
    /// out of view goes to the workspace that comes into view, or to the workspace that the window makes ahead), and
    /// the tab that the window shows after each key has a page view.
    ///
    /// The setup counts no page as used (`usedPages` false): each New Tab page of the row is one that the person did
    /// not touch, the app's own first page too. With the pages counted as used, the workspaces that the window makes
    /// ahead for the first 2 keys find no page view to take and get a new one each. The window has its made-ahead
    /// workspace before the row's own key, as an app that rested has. Each creation is answered before the row ends:
    /// the row's window closes then.
    @Test(arguments: [20]) func aHoldOfNewWorkspaceKeysMakesOnePageViewAtMost(keys: Int) async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-hold-other-screens-workspaces", usedPages: false) { services, _, _, _ in
            let tabs = services.agentTabs, store = services.daemon.store
            let controller = try #require(services.windows.active, "setup: no window")
            let views = Moves.Views()
            let moves = PageMoves(services) // each page view event of the row, with who asked: a print only
            defer { moves.restore() }
            let builds = Builds(services) { key in
                if controller.content?.panes.values.contains(where: { Self.has($0, key, tabs) }) == true { return "a tab of the workspace that the window showed then" }
                if controller.reservedContent.ready?.panes.values.contains(where: { Self.has($0, key, tabs) }) == true { return Builds.madeAhead }
                for parked in controller.parked.values where parked.panes.values.contains(where: { Self.has($0, key, tabs) }) {
                    return "a tab of a workspace that the window showed before"
                }
                return nil
            }
            let wired = tabs.onPageBuilt
            tabs.onPageBuilt = { key in
                builds.note(key)
                wired?(key)
            }
            defer { tabs.onPageBuilt = wired }
            try await Moves.makesItsWorkspaceAhead(controller, services, row: "cn-hold-other-screens-workspaces")
            // The page views of New Tab pages that the store has now, in each workspace.
            @MainActor func read() -> Int {
                let now = tabs.views.values.filter { $0.model.newTab != nil }
                now.forEach(views.note)
                moves.sync()
                return now.count
            }
            // One New Workspace key and its frame. Returns whether the tab that the window shows then has a page view.
            @MainActor func press() async throws -> Bool {
                let before = Set(store.workspaces.map(\.id))
                try #require(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)), "setup: the New Workspace key was refused")
                await NewTabPageAtItsFrameTests.frame(services)
                let made = try #require(store.workspaces.first { !before.contains($0.id) }?.id, "setup: the New Workspace key made no workspace in its turn")
                try await PasswordManagerRouteTests.until({ controller.content?.workspace.id == made && controller.content?.focusedPane != nil },
                                                          within: .seconds(5), report: { "setup: the window shows no focused pane of the key's workspace" })
                await NewTabPageAtItsFrameTests.frame(services)
                let shown = controller.content?.focusedPane?.currentTabKey
                return shown.map { tabs.isNewTabPage($0) && tabs.existingView($0) != nil } ?? false
            }
            _ = read()
            builds.part = "the row's own key"
            let firstHasPage = try await press()
            try #require(firstHasPage, "setup: the workspace of the row's own New Workspace key shows no New Tab tab with a page view")
            let atStart = read(), before = views.count
            var pressed = 0, withNoPage = 0, most = atStart
            var notAhead: [Int] = [], madeAt: [Int] = []
            for key in 1...keys {
                builds.part = "key \(key)"
                if controller.reservedContent.ready == nil { notAhead.append(key) }
                let had = views.count
                let hasPage = try await press()
                if !hasPage { withNoPage += 1 }
                pressed += 1
                most = max(most, read())
                if views.count > had { madeAt.append(key) }
                if views.count - before > 2 { break }
            }
            let made = views.count - before
            builds.part = "after the hold"
            try await PasswordManagerRouteTests.until({ !store.workspaces.contains(where: \.isProvisional) },
                                                      report: { "the daemon did not answer each New Workspace key of the row" })
            let listed = builds.listed
            print("""
                NewTabHoldOtherScreensTests: row 12, a hold of \(keys) New Workspace keys: \(pressed) keys pressed, \(made) page \
                views made in the hold, first seen after the keys \(madeAt); the store had \(atStart) page views of New Tab pages \
                before the hold and \(most) at one time at most in it; after \(withNoPage) keys the window showed a tab with no \
                page view; the window had no made-ahead workspace at the keys \(notAhead); the store's build hook, each call: \
                \(listed); new page views whose tab the row has no name for: \(builds.notNamed); the page views, each event: \(moves.lines)
                """)
            #expect(pressed == keys, "the hold stopped after key \(pressed) of \(keys): \(made) page views were made by then, want 1 at most for the whole hold")
            #expect(made <= 1, "\(made) page views were made in a hold of \(pressed) New Workspace keys (first seen after the keys \(madeAt)), want 1 at most. The store's build hook, each call: \(listed)")
            #expect(withNoPage == 0, "after \(withNoPage) of \(pressed) keys the window showed a tab with no page view")
        }
    }
}
