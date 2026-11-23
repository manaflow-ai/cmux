import AppKit
@testable import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The rows of the suite for the web New Tab page (the default kind) and for a key from a terminal, in an app with
/// its own daemon: a second page takes the list that is there, two pages of one frame start no listing, and a first
/// key from a terminal is one listing under one focus.
extension NewTabCommandListKeptTests {
    /// The web New Tab page (the default kind), with no prepared page as in a hold: a second page takes the list that is
    /// there, in place, with no read. Its person's first input reads the actions again with no ask of the row, in later frames.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aSecondWebPageTakesTheListWithNoNewReadAndReadsAgainAtItsFirstInput() async throws {
        try await Self.web("cn-list-kept-web") { web in
            let services = web.services, tabs = services.agentTabs, lister = services.newTabActions
            let before = lister.counts
            NewTabPage.open(in: web.pane, seed: nil)
            let key = Self.focus(services)
            // Two asks: a page whose view is made after the first hand-over has the list at the second.
            let handed = await Self.listed(services)
            let again = await Self.listed(services)
            let shown = lister.counts
            let pages = web.others()
            print("new-tab-list: a second web page: \(shown.started - before.started) listings started, \(shown.actionsRead - before.actionsRead) catalog "
                + "actions read again, \(handed.frames) + \(again.frames) frames with a lister task; the focus context \(key) in the key's turn, \(Self.focus(services)) now")
            #expect(shown.started == before.started,
                    "the second page started \(shown.started - before.started) listings and read \(shown.actionsRead - before.actionsRead) catalog actions again")
            try #require(pages.count == 1, "the fixture did not make the case: the second key opened \(pages.count) New Tab pages: \(web.named(pages))")
            let view = try #require(tabs.views[pages[0]], "the second page has no view after two hand-overs")
            #expect(view.model.newTab?.omnibar.actions == web.list.actions,
                    "the second page has \(view.model.newTab?.omnibar.actions.count ?? 0) of the \(web.list.actions.count) actions")

            // The page's own report of its person's first input. The row asks for nothing: it is only the display.
            let frames = services.mainWork.frames
            try #require(!frames.activeClients.contains(Self.lister), "the lister has a task before the first input")
            _ = await view.model.respond(to: .touched)
            // The write of the page's flag only asks for the read, in the main queue's next turn: no task in its own.
            #expect(!frames.activeClients.contains(Self.lister), "the first input's own turn queued a task of the lister")
            #expect(lister.counts == shown, "the first input's own turn started \(lister.counts.started - shown.started) listings")
            // Exactly one turn of the main queue: a block of the row's own, which the queue runs after the app's. The
            // lister has its task then: an ask two turns away is an issue here. The app's own display can fire a
            // frame before the row runs again, so the listing's first task may have run; no action is read to an end.
            await withCheckedContinuation { turn in DispatchQueue.main.async { turn.resume() } }
            #expect(frames.activeClients.contains(Self.lister), "one turn of the main queue after the first input the lister has no task")
            #expect(lister.counts.actionsRead == shown.actionsRead, "the turn after the first input read a listing to its end")
            let limit = Self.frameLimit(services)
            var fired = 0
            while lister.counts.started == shown.started, fired < limit {
                services.mainWork.frameDidFire()
                fired += 1
            }
            let started = lister.counts
            #expect(started.started == shown.started + 1, "the first input started \(started.started - shown.started) listings in \(fired) frames")
            let read = await Self.listed(services)
            let end = lister.counts
            print("new-tab-list: the first input in a web page: the listing's first task after \(fired) frames of the row; \(end.started - shown.started) listings "
                + "started, \(end.actionsRead - shown.actionsRead) catalog actions read, \(read.frames) frames with a lister task after the row's ask")
            #expect(end.started == shown.started + 1, "the first input and one ask started \(end.started - shown.started) listings")
        }
    }

    /// Two New Tab keys inside one frame (a large session has long frames): the older page is not its pane's selection at the
    /// next frame, so it has no view at the lister's first task. The pages start no listing; the older takes the list, with no read, at its view's make.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func twoWebPagesInOneFrameStartNoListing() async throws {
        try await Self.web("cn-list-kept-web-pair") { web in
            let services = web.services, tabs = services.agentTabs, lister = services.newTabActions
            let before = lister.counts
            // No frame and no turn of the main thread comes between the two keys.
            NewTabPage.open(in: web.pane, seed: nil)
            NewTabPage.open(in: web.pane, seed: nil)
            let key = Self.focus(services)
            let handed = await Self.listed(services)
            let again = await Self.listed(services)
            let held = lister.counts
            // The keys from here on are the store's ids: the row knows the older page by its tab after the select.
            try await Self.settle(services)
            let pair = web.others()
            let unseen = pair.filter { tabs.views[$0] == nil }
            print("new-tab-list: two web pages in one frame: \(pair.count) pages, \(unseen.count) with no view; \(held.started - before.started) listings "
                + "started, \(held.actionsRead - before.actionsRead) catalog actions read again, \(handed.frames) + \(again.frames) frames with a lister "
                + "task; the focus context \(key) in the keys' turn, \(Self.focus(services)) now")
            #expect(held.started == before.started,
                    "the two pages started \(held.started - before.started) listings and read \(held.actionsRead - before.actionsRead) catalog actions again")
            try #require(pair.count == 2 && unseen.count == 1,
                         "the fixture did not make the case: \(pair.count) pages, \(unseen.count) with no view: \(web.named(pair))")
            let newer = try #require(pair.compactMap { tabs.views[$0] }.first)
            #expect(newer.model.newTab?.omnibar.actions == web.list.actions,
                    "the page with a view has \(newer.model.newTab?.omnibar.actions.count ?? 0) of the \(web.list.actions.count) actions")

            // The person selects the older page: its view is made at the next frame.
            web.pane.select(CmuxNextTabs.TabID(unseen[0].key))
            let made = await Self.listed(services)
            let last = await Self.listed(services)
            let end = lister.counts
            // By its tab: the older page can show in the view that the newer page had (the pane leaves the newer page's tab).
            let older = tabs.views[unseen[0]]
            print("new-tab-list: the older page at its view's make: \(end.started - held.started) listings started, \(end.actionsRead - held.actionsRead) "
                + "catalog actions read again, \(made.frames) + \(last.frames) frames with a lister task")
            let view = try #require(older, "the older page has no view after it was selected")
            #expect(view.model.newTab?.omnibar.actions == web.list.actions,
                    "the older page has \(view.model.newTab?.omnibar.actions.count ?? 0) of the \(web.list.actions.count) actions")
            #expect(end.started == held.started,
                    "the older page started \(end.started - held.started) listings and read \(end.actionsRead - held.actionsRead) catalog actions again")
        }
    }

    /// The same two keys, and then a change of a key binding before the person selects the older page: no list is kept
    /// at the select. The view of the older page is made on the app's own path (the pane's select, then the tab store),
    /// and that make asks for the fill. One listing reads the actions under the keys of now, and the view shows that
    /// list. The row's asks give a list to no view: a view that has the list of now got it from the app's fill.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func anOlderWebPageSelectedAfterAChangeOfAKeyBindingShowsTheListOfNow() async throws {
        try await Self.web("cn-list-kept-web-rebind") { web in
            let services = web.services, tabs = services.agentTabs, lister = services.newTabActions
            // No frame and no turn of the main thread comes between the two keys.
            NewTabPage.open(in: web.pane, seed: nil)
            NewTabPage.open(in: web.pane, seed: nil)
            _ = await Self.listed(services)
            _ = await Self.listed(services)
            // The keys from here on are the store's ids: the row knows the older page by its tab after the select.
            try await Self.settle(services)
            let pair = web.others()
            let unseen = pair.filter { tabs.views[$0] == nil }
            try #require(pair.count == 2 && unseen.count == 1,
                         "the fixture did not make the case: \(pair.count) pages, \(unseen.count) with no view: \(web.named(pair))")
            let old = Self.keys(web.list.actions)
            Self.rebind(services)
            try #require(lister.kept == nil, "the row did not make its case: a list is kept after the change of the key binding")
            try #require(!services.mainWork.frames.activeClients.contains(Self.lister), "the row did not make its case: the lister has a task before the select")
            let before = lister.counts

            // The person selects the older page. The row's first ask joins the listing that the view's make asks for, or
            // that make's ask joins the row's: one listing in each order.
            web.pane.select(CmuxNextTabs.TabID(unseen[0].key))
            let made = await Self.listed(services)
            let last = await Self.listed(services)
            let end = lister.counts
            // By its tab: the older page can show in the view that the newer page had (the pane leaves the newer page's tab).
            let older = tabs.views[unseen[0]]
            let now = try #require(last.list, "the ask after the select never got a list")
            let keys = Self.keys(now.actions), has = older?.model.newTab?.omnibar.actions
            print("new-tab-list: an older web page selected after a change of a key binding: \(end.started - before.started) listings started, "
                + "\(end.actionsRead - before.actionsRead) catalog actions read, \(made.frames) + \(last.frames) frames with a lister task; its New "
                + "Tab row shows the keys \(Self.keys(has)) and it has \(has?.count ?? 0) rows; the list of now has the keys \(keys) and "
                + "\(now.actions.count) rows; the list of before the change had the keys \(old)")
            try #require(!old.isEmpty && keys != old, "the row did not make its case: the New Tab row shows the keys \(keys) after the change and \(old) before it")
            let view = try #require(older, "the older page has no view after it was selected")
            #expect(view.model.newTab?.omnibar.actions == now.actions,
                    "the older page shows the keys \(Self.keys(has)) in its New Tab row (\(has?.count ?? 0) rows); the list of now has the keys \(keys) (\(now.actions.count) rows)")
            #expect(end.started == before.started + 1, "the select of the older page and the row's 2 asks started \(end.started - before.started) listings where 1 is wanted")
        }
    }

    /// A web page's run of a command row gives the title that the app's copy of the page's list has. A row with the title
    /// of now runs. That run changes the state and no member of the registry, so the copy's title is old then: a second
    /// run of the row runs nothing, the actions are read again, and the copy's row has the title of now.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aWebPagesRunOfARowRunsItOnlyUnderTheTitleOfNow() async throws {
        try await Self.web("cn-list-kept-web-title") { web in
            let services = web.services, lister = services.newTabActions, view = web.first
            let (store, id) = try Self.collapseRow(services)
            // The bind is a write of the registry: the app reads the actions again for its pages.
            NewTabPage.fillPaletteActions(services, again: true)
            _ = await Self.listed(services)
            let row = view.model.newTab?.omnibar.actions.first { $0.id == id }
            let shown = try #require(row, "the row did not make its case: the page's list of \(view.model.newTab?.omnibar.actions.count ?? 0) rows has no row \(id)")
            _ = await view.model.respond(to: .appAction(id))
            let first = store.isCollapsed
            // The second half starts from the collapsed state in each case.
            store.setCollapsed(true)
            try #require(view.model.newTab?.omnibar.actions.first { $0.id == id } == shown, "the row did not make its case: the first run changed the page's row")
            let before = lister.counts
            _ = await view.model.respond(to: .appAction(id))
            let ran = !store.isCollapsed
            let read = await Self.listed(services)
            let end = lister.counts
            let now = view.model.newTab?.omnibar.actions.first { $0.id == id }
            print("new-tab-list: a web page's run of a row: under '\(shown.title)', the title of now, the run \(first ? "ran it" : "ran nothing"); the second run "
                + "\(ran ? "ran it" : "ran nothing"), \(end.started - before.started) listings started after it, the row has '\(now?.title ?? "no row")' after the hand-over")
            #expect(first, "the row showed '\(shown.title)', the title of now, and its run did not collapse the tabs")
            #expect(!ran, "the row showed '\(shown.title)' with the tabs collapsed, and its run expanded them")
            #expect(read.list != nil && end.started == before.started + 1, "the refused run started \(end.started - before.started) listings where 1 is wanted")
            #expect(now != nil && now?.title != shown.title, "after the refused run the row has '\(now?.title ?? "no row")', and it had '\(shown.title)' before")
        }
    }

    /// The reads of the pages by a row's fills, as a count.
    @MainActor private final class PageReads { var count = 0 }

    /// A web page that no person used goes back to the prepared pages, and each later New Tab key gives it an empty list
    /// and then the kept one. Three such turns, then the page's first input: one fill reads the actions again, not one for
    /// each turn. A fill that reads again reads the pages 2 times: at the listing's first task and at its hand-over.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aPageThatTookTheKeptListThreeTimesIsFilledOnceAtItsFirstInput() async throws {
        try await Self.web("cn-list-kept-web-turns") { web in
            let services = web.services, lister = services.newTabActions, view = web.first, frames = services.mainWork.frames
            let reads = PageReads()
            let pages: @MainActor @Sendable () -> [AgentPaneNewTabActions.Page] = {
                reads.count += 1
                return [AgentPaneNewTabActions.Page(view: view)]
            }
            try #require(!view.model.userTouched, "the row did not make its case: the first page has an input already")
            let before = lister.counts
            let limit = Self.frameLimit(services)
            for turn in 1...3 {
                // No ask of the app is in the air when the page loses its list: the row's fill is the first one that hands it a list.
                var fired = 0
                while frames.activeClients.contains(Self.lister), fired < limit {
                    services.mainWork.frameDidFire()
                    fired += 1
                    await Task.yield()
                }
                try #require(!frames.activeClients.contains(Self.lister), "the row did not make its case: the lister has a task before turn \(turn)")
                var empty = try #require(view.model.newTab, "the first page is no New Tab page any more")
                empty.omnibar.actions = []
                view.model.adoptNewTab(empty)
                lister.fill(pages)
                _ = await Self.listed(services)
                try #require(view.model.newTab?.omnibar.actions == web.list.actions && lister.counts == before,
                             "the row did not make its case: turn \(turn) did not take the kept list (\(lister.counts.started - before.started) listings started)")
            }
            let asked = reads.count
            _ = await view.model.respond(to: .touched)
            // The write of the page's flag asks in the main queue's next turn.
            await withCheckedContinuation { turn in DispatchQueue.main.async { turn.resume() } }
            let read = await Self.listed(services)
            let end = lister.counts
            let more = reads.count - asked
            print("new-tab-list: the first input in a web page that took the kept list 3 times: \(more) reads of the pages (2 for each fill), "
                + "\(end.started - before.started) listings started")
            #expect(more == 2, "the first input made \(more / 2) fills (\(more) reads of the pages) where 1 fill is wanted")
            #expect(read.list != nil && end.started == before.started + 1, "the first input started \(end.started - before.started) listings where 1 is wanted")
        }
    }

    // MARK: - A key from a terminal

    /// The focus contexts that the slices of one listing read under, in their order (one value while it holds).
    @MainActor private final class Slices { var contexts: [String] = [] }

    /// A New Tab key from a terminal with no kept list: the focus goes from the terminal to the page. One listing reads
    /// the list, each slice under the focus context of the hand-over, and the list is kept: a second ask starts none.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aFirstKeyFromATerminalIsOneListingUnderOneFocus() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-list-kept-terminal")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (_, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let pool = services.newTabSpares
            pool.dropAll()
            pool.makeSpare = { _ in nil }
            defer { pool.makeSpare = nil }
            // The fixture: a terminal tab of the pane has the focus. These waits are the fixture's, not the row's.
            let store = services.daemon.store
            let surface = try await connection.newTab(in: pane.pane.handle).surface
            try await PasswordManagerRouteTests.until({ store.tab(surface: surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true },
                                                      report: { "setup: the pane's strip does not list the new terminal tab" })
            let terminal = try #require(store.tab(surface: surface), "setup: the store has no tab for the new terminal")
            pane.select(CmuxNextTabs.TabID(terminal.id))
            try await PasswordManagerRouteTests.until({ services.registry.context.contains(.terminalFocused) },
                                                      report: { "setup: the focus context \(Self.focus(services)) has no terminal" })
            try await Self.settle(services)
            // The fixture is the display to the hand-over of the launch page's list. Then one key binding's change is a catalog change.
            let launch = await Self.listed(services)
            services.registry.setShortcutOverride(CmuxNextActions.Shortcut("t", modifiers: [.control]), for: "newTab.default")
            let lister = services.newTabActions, tabs = services.agentTabs
            let known = Set(tabs.newTabPages.keys), before = lister.counts, start = Self.focus(services)
            // The row's case: no listing in the air at the key (the lister has no task, the last list was handed over).
            let inAir = services.mainWork.frames.activeClients.contains(Self.lister) || launch.list == nil
            print("new-tab-list: a listing in the air at the key: \(inAir ? "yes" : "no") (\(before.started) listings started before the key, "
                + "\(before.actionsRead) catalog actions read; the fixture \(launch.list == nil ? "got no hand-over" : "took the last hand-over"))")
            try #require(!inAir, "the row did not make its case: a listing is in the air at the key")
            NewTabPage.open(in: pane, seed: nil)
            // The row's ask joins the page's listing. A frame whose task reads a slice notes the slice's focus context.
            let key = Self.focus(services), slices = Slices()
            let cold = await Self.listed(services) {
                let counts = lister.counts, focus = Self.focus(services)
                guard counts.started > before.started, counts.actionsRead == before.actionsRead else { return }
                if slices.contexts.last != focus { slices.contexts.append(focus) }
            }
            let handed = Self.focus(services), first = lister.counts
            let again = await Self.listed(services)
            let end = lister.counts
            print("new-tab-list: a first key from a terminal: \(first.started - before.started) listings started, its slices read under the focus "
                + "contexts \(slices.contexts); a second ask: \(end.started - first.started) listings started, \(end.actionsRead - first.actionsRead) "
                + "catalog actions read again; \(cold.frames) + \(again.frames) frames with a lister task; the focus context \(start) before the key, "
                + "\(key) in the key's turn, \(handed) after the first hand-over, \(Self.focus(services)) now")
            try #require(first.started > before.started, "the row did not make its case: the key started no listing (it joined one, or a list was kept)")
            #expect(first.started == before.started + 1, "the first key from a terminal started \(first.started - before.started) listings")
            #expect(slices.contexts == [handed], "the listing's slices read under the focus contexts \(slices.contexts); the page has \(handed) at the hand-over")
            #expect(end.started == first.started, "a second ask started \(end.started - first.started) listings")
            // Exactly one new page, then its view: a second new page with a view would hide a page of the key that has none.
            let pages = Self.opened(services, after: known)
            try #require(pages.count == 1, "the key opened \(pages.count) New Tab pages where 1 is wanted: \(Self.named(pages, services, pane))")
            let view = try #require(tabs.views[pages[0]], "the key's page has no view after its listing: \(Self.named(pages, services, pane))")
            #expect(cold.list != nil && view.model.newTab?.omnibar.actions == again.list?.actions, "the page does not show the list of now")
        }
    }

    // MARK: - The fixture

    /// What a web row starts from: an app with one web New Tab page of the row's own key that has the palette's actions.
    @MainActor private struct Web {
        let services: AppServices
        let pane: PaneController
        /// The view that the first page has at the row's start. It is not the page: a later New Tab tab of the pane can take it.
        let first: AgentPaneView
        /// The list the lister gives with the focus on the first page.
        let list: Listed
        /// The keys of the New Tab pages before the first one (the launch's own page) and the first one's: the store's ids.
        let known: Set<AgentTabKey>, page: AgentTabKey

        /// The New Tab pages that came after the first one, by their keys of now.
        func others() -> [AgentTabKey] { NewTabCommandListKeptTests.opened(services, after: known.union([page])) }

        /// What each of `keys` is, for the words of a fixture's issue: a count of pages that is not the row's names its pages.
        func named(_ keys: [AgentTabKey]) -> String { NewTabCommandListKeptTests.named(keys, services, pane) }
    }

    /// What each of `keys` is, for the words of an issue: its key, if it has a view, and if it is a tab of `pane`.
    static func named(_ keys: [AgentTabKey], _ services: AppServices, _ pane: PaneController) -> String {
        let inPane = Set(pane.pane.tabs.map(\.id))
        let words = keys.map { key in
            let view = services.agentTabs.views[key] == nil ? "no view" : "a view"
            let place = inPane.contains(key.key) ? "a tab of the row's pane" : "no tab of the row's pane"
            return "\(key.key) (\(view), \(place))"
        }
        return words.joined(separator: ", ")
    }

    /// The New Tab pages that were not there before, by their keys of now: a page's key changes at the store's answer.
    /// A page of before is known by its tab: `known` has the store's id of each (``settle(_:)``), which does not change.
    /// Not by its view: a New Tab tab that a pane shows takes the page view of an untouched New Tab tab that the pane
    /// leaves or that no pane shows (`AgentTabStore.idlePage`): the view of a page of before can be a new page's view.
    /// The page of the next workspace is none of them: the app makes it ahead of its key in idle frames (the row's own
    /// frames too), so it can come at any frame of a row.
    static func opened(_ services: AppServices, after known: Set<AgentTabKey>) -> [AgentTabKey] {
        let tabs = services.agentTabs
        let ahead = services.daemon.store.reservedWorkspace?.tabKey
        return tabs.newTabPages.keys.filter { key in key.key != ahead && !known.contains(key) }
    }

    /// Waits until each New Tab page has the store's id of its tab as its key (the next workspace's page has none before
    /// its key). A tab that the app made has a provisional id until the store answers; its page goes to the store's id
    /// then, and the app keeps the link of the two ids only while the store lists the provisional tab. So the fixture
    /// takes the keys of before only when no answer is in the air. This wait is the fixture's, not the row's.
    static func settle(_ services: AppServices) async throws {
        let tabs = services.agentTabs, store = services.daemon.store
        @MainActor func waiting() -> [String] {
            tabs.newTabPages.keys.map(\.key).filter { ProvisionalTab.isProvisional($0) && $0 != store.reservedWorkspace?.tabKey }
        }
        try await PasswordManagerRouteTests.until({ waiting().isEmpty },
                                                  report: { "setup: the store did not answer for the New Tab pages \(waiting())" })
    }

    /// The registry's focus context, as a number for a print.
    private static func focus(_ services: AppServices) -> String { "\(services.registry.context.rawValue)" }

    /// Runs `body` in an app (with its own daemon) whose pane shows one web New Tab page that has the list. No page
    /// is prepared (the pool gives no spare), as in a hold. A page is not always made cold: the tab of a New Tab key
    /// takes the page view of the tab that the pane leaves while no person used that view, here the launch page's
    /// view at the first key. The view gets the new tab's own page at the take; the tab that it leaves has no view then.
    private static func web(_ install: String, _ body: @MainActor (Web) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: install)
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (_, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let pool = services.newTabSpares
            pool.dropAll()
            pool.makeSpare = { _ in nil }
            defer { pool.makeSpare = nil }
            let tabs = services.agentTabs
            // The read below knows a page of before by its tab: by the store's id of it.
            try await settle(services)
            // The fixture is the display, with no clock, while the page that the pane shows has no view: the first key's
            // tab can take that view only when it is there. A Mac with a late display made no frame yet.
            let limit = frameLimit(services)
            var settled = 0
            while pane.currentTabKey.flatMap({ tabs.existingView($0) }) == nil, settled < limit {
                services.mainWork.frameDidFire()
                settled += 1
                await Task.yield()
            }
            try #require(pane.currentTabKey.flatMap({ tabs.existingView($0) }) != nil, "setup: the page that the pane shows has no view after \(settled) frames of the fixture")
            let known = Set(tabs.newTabPages.keys)
            let start = focus(services)
            NewTabPage.open(in: pane, seed: nil)
            let key = focus(services)
            let cold = await listed(services)
            let read = focus(services)
            // The focus goes to the page in its first frames. A second ask gives the list of that focus.
            let again = await listed(services)
            let list = try #require(again.list, "the first page's second ask never got a list")
            // The first page's key is the store's id from here on: a row knows the later pages against it.
            try await settle(services)
            let page = try #require(opened(services, after: known).first { tabs.views[$0] != nil }, "Cmd-T opened no New Tab page with a view")
            let first = try #require(tabs.views[page], "the first page has no view after its listing")
            try #require(!list.actions.isEmpty && first.model.newTab?.omnibar.actions.isEmpty == false, "the first page did not get a list")
            let counts = services.newTabActions.counts
            print("new-tab-list: the first web page: \(counts.started) listings started in two asks, \(cold.frames) + \(again.frames) frames with a lister "
                + "task; the focus context \(start) before the key, \(key) in the key's turn, \(read) after the first hand-over, \(focus(services)) now; "
                + "\(settled) frames of the fixture before the key, \(known.count) New Tab pages before it")
            try await body(Web(services: services, pane: pane, first: first, list: list, known: known, page: page))
        }
    }
}
