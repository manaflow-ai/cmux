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

/// What a New Tab page costs in listings of the Commands palette's actions (``AgentPaneNewTabActions``).
///
/// The page's bar lists every action the palette could run. One listing reads the state of each catalog action,
/// a slice in each display frame, so a page has no command row for some hundred frames. The list depends on what
/// is focused and on the registry, not on the page: a page that shows while the last list still holds needs no
/// read at all. These rows hold that by counts (``AgentPaneNewTabActions/Counts``), never by a clock: the row
/// fires each display frame itself.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .closesItsWindows)
struct NewTabCommandListKeptTests {
    private typealias Listed = AgentPaneNewTabActions.Listed

    /// A second page, with the same kind of focus and no change of the registry since the first one's list, has
    /// the palette's actions in the turn that shows it, and no catalog action is read again for it.
    @Test func aSecondPageHasThePalettesActionsWhenItShowsWithNoNewRead() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let lister = app.services.newTabActions
        let first = try Self.openPage(app)
        first.loadPaletteActions()
        let cold = await Self.listed(app.services)
        let list = try #require(cold.list, "the first page's listing never handed its list over")
        try #require(!list.actions.isEmpty && first.page.omnibar.actions == list.actions, "the first page did not get the list")
        let before = lister.counts
        Self.report("the first page's listing", before, frames: cold.frames, of: list, in: app.services)

        let second = try Self.openPage(app)
        #expect(second.page.omnibar.actions == list.actions,
                "the second page shows with \(second.page.omnibar.actions.count) of the \(list.actions.count) actions")
        // The page's own ask (its hook two frames after it shows, or the first keystroke), then the row's.
        second.loadPaletteActions()
        let again = await Self.listed(app.services)
        let after = lister.counts
        print("new-tab-list: the second page: \(after.started - before.started) listings started, "
            + "\(after.actionsRead - before.actionsRead) catalog actions read again in \(again.frames) frames with a lister task")
        #expect(after.started == before.started, "the second page started \(after.started - before.started) more listings")
        #expect(after.actionsRead == before.actionsRead,
                "the second page read \(after.actionsRead - before.actionsRead) catalog actions again, in \(again.frames) frames with a lister task")
    }

    /// A request that comes after a listing's last slice and before its hand-over joins that list: the finished
    /// list is handed over as it is, and no new read starts.
    @Test func aRequestBeforeTheHandOverKeepsTheFinishedList() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services
        let lister = services.newTabActions
        let page = try Self.openPage(app)
        let start = lister.counts
        page.loadPaletteActions()
        // The row is the display. No turn of the main thread ends between these frames, and the hand-over needs
        // one (the list's JSON is made off the main thread), so it cannot come before the second request.
        // The lister adds a listing's actions to its count in the task that reads the last of them.
        let limit = Self.frameLimit(services)
        var fired = 0
        while lister.counts.actionsRead == start.actionsRead, fired < limit {
            services.mainWork.frameDidFire()
            fired += 1
        }
        let read = lister.counts
        try #require(read.actionsRead > start.actionsRead, "no listing was read to its end in \(fired) frames: \(read)")
        try #require(page.page.omnibar.actions.isEmpty, "the list was handed over in the frame of its last slice")

        let asked = await Self.listed(services)
        let list = try #require(asked.list, "the second request never got a list")
        let end = lister.counts
        print("new-tab-list: a request before the hand-over: \(end.started - start.started) listings started, "
            + "\(end.actionsRead - read.actionsRead) catalog actions read again")
        #expect(page.page.omnibar.actions == list.actions, "the page and the second request did not get one list")
        #expect(end.started == read.started,
                "a request before the hand-over started \(end.started - read.started) more listings (\(end.actionsRead - read.actionsRead) catalog actions read again)")
    }

    /// A hold of the New Tab key after a list was read: each of its ten pages shows with the palette's actions, and
    /// the hold starts no listing.
    @Test func aHoldOfTenPagesStartsNoListing() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services
        let lister = services.newTabActions
        let first = try Self.openPage(app)
        first.loadPaletteActions()
        let cold = await Self.listed(services)
        let list = try #require(cold.list, "the first page's listing never handed its list over")
        let before = lister.counts

        var without = 0
        for _ in 0..<10 {
            let page = try Self.openPage(app)
            if page.page.omnibar.actions != list.actions { without += 1 }
            // A held key gives a page each 33 ms: two frames at 60 Hz. Then the page asks, as its hook does.
            services.mainWork.frameDidFire()
            services.mainWork.frameDidFire()
            page.loadPaletteActions()
        }
        let held = await Self.listed(services)
        let after = lister.counts
        print("new-tab-list: a hold of 10 pages: \(without) pages showed without the actions, \(after.started - before.started) listings started, "
            + "\(after.actionsRead - before.actionsRead) catalog actions read again in \(held.frames) frames with a lister task after the last page")
        #expect(without == 0, "\(without) of the 10 pages showed without the palette's actions")
        #expect(after.started == before.started,
                "the hold started \(after.started - before.started) listings and read \(after.actionsRead - before.actionsRead) catalog actions again")
    }

    /// What a hold of the New Tab key did, as its driver saw it.
    @MainActor private final class Hold {
        var pages: [NativeNewTabModel] = []
        var asks = 0
        /// Frames the lister had a task for.
        var frames = 0
        /// The lister's counts in the turn of the hand-over.
        var handed: AgentPaneNewTabActions.Counts?
        var failure: String?
    }

    /// A hold of the New Tab key in a window that has no list yet, for as long as the listing takes: an ask each two
    /// frames from the first frame until the hand-over (the first ten are pages). One listing serves them all, and
    /// each of its pages has that list.
    @Test func aHoldWithNoListYetIsOneListing() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services
        let lister = services.newTabActions
        let start = lister.counts
        let limit = Self.frameLimit(services)
        let hold = Hold()
        let (lists, feed) = AsyncStream.makeStream(of: Listed.self)
        // The held key and the display in one: it ends only when the row cancels it.
        let key = Task { @MainActor in
            while !Task.isCancelled {
                if hold.handed == nil, hold.failure == nil {
                    if hold.pages.count < 10 {
                        do {
                            let page = try Self.openPage(app)
                            page.loadPaletteActions()
                            hold.pages.append(page)
                        } catch {
                            hold.failure = "page \(hold.pages.count + 1) of the hold did not open: \(error)"
                            feed.finish()
                        }
                    }
                    // The row's ask, as a page's: every waiter gets the list in the turn of the hand-over.
                    lister.list(wanted: { true }) { list in
                        guard hold.handed == nil else { return }
                        hold.handed = lister.counts
                        feed.yield(list)
                        feed.finish()
                    }
                    hold.asks += 1
                }
                // A held key gives a page each 33 ms: two frames at 60 Hz. No turn of the main thread ends between
                // an ask and its two frames; one ends after them (the list's JSON comes back to the main thread there).
                for _ in 0..<2 {
                    if services.mainWork.frames.activeClients.contains(Self.lister) {
                        hold.frames += 1
                        if hold.frames == limit + 1 {
                            hold.failure = "no hand-over in \(limit) frames with a lister task"
                            feed.finish()
                        }
                    }
                    services.mainWork.frameDidFire()
                }
                await Task.yield()
            }
        }
        var got: Listed?
        for await list in lists { got = list }
        key.cancel()
        await key.value
        let now = lister.counts
        let end = hold.handed ?? now
        print("new-tab-list: a hold with no list yet: \(hold.asks) asks, one each 2 frames, until the hand-over; "
            + "\(end.started - start.started) listings started, "
            + "\(end.actionsRead - start.actionsRead) catalog actions read, \(hold.frames) frames with a lister task")
        let list = try #require(got, "\(hold.failure ?? "no hand-over"); \(hold.asks) asks; listings started = \(now.started - start.started)")
        let without = hold.pages.filter { $0.page.omnibar.actions != list.actions }.count
        #expect(end.started == start.started + 1, "the hold started \(end.started - start.started) listings in \(hold.asks) asks")
        #expect(without == 0, "\(without) of the hold's \(hold.pages.count) pages do not have the list after its hand-over")
    }

    /// The first letter in a page that showed with the kept list reads the actions again, and never in its own
    /// turn: the keystroke's turn reads no action and starts no listing (it queues the listing's first task for a
    /// later frame), and a second letter while that listing runs starts no second one.
    @Test func theFirstLetterReadsTheActionsAgainInLaterFrames() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services
        let lister = services.newTabActions
        let first = try Self.openPage(app)
        first.loadPaletteActions()
        let cold = await Self.listed(services)
        let list = try #require(cold.list, "the first page's listing never handed its list over")
        let page = try Self.openPage(app)
        try #require(page.page.omnibar.actions == list.actions, "the second page did not show with the kept list")
        let before = lister.counts

        page.text = "a"
        let typed = lister.counts
        #expect(typed == before, "the first letter's turn started \(typed.started - before.started) listings and read \(typed.actionsRead - before.actionsRead) catalog actions")
        #expect(services.mainWork.frames.activeClients.contains(Self.lister), "the first letter queued no task of the lister")

        // The row is the display: the listing's first task runs in one of these frames, never in the letter's turn.
        let limit = Self.frameLimit(services)
        var fired = 0
        while lister.counts.started == before.started, fired < limit {
            services.mainWork.frameDidFire()
            fired += 1
        }
        let running = lister.counts
        try #require(running.started == before.started + 1, "the first letter started no listing in \(fired) frames")
        try #require(running.actionsRead == before.actionsRead, "the listing ended in its first task")
        // A second letter while the listing runs.
        page.text = "ab"
        let again = await Self.listed(services)
        let end = lister.counts
        // A third letter: the page's own listing read its list, so it asks for nothing more.
        page.text = "abc"
        let third = await Self.listed(services)
        let last = lister.counts
        print("new-tab-list: the first letter in a page with the kept list: \(typed.started - before.started) listings started and "
            + "\(typed.actionsRead - before.actionsRead) catalog actions read in its turn, the listing's first task \(fired) frames later; "
            + "\(end.started - before.started) listings started and \(end.actionsRead - before.actionsRead) catalog actions read to the hand-over, "
            + "\(again.frames) frames with a lister task after the second letter; a third letter: \(last.started - end.started) listings started")
        #expect(again.list != nil && third.list != nil)
        #expect(end.started == before.started + 1, "two letters started \(end.started - before.started) listings")
        #expect(end.actionsRead > before.actionsRead, "the first letter's listing read no catalog action")
        #expect(last.started == end.started, "a third letter started \(last.started - end.started) more listings")
    }

    // MARK: - The web page

    /// The web New Tab page (the default kind), made cold as the pages of a hold are: a second page takes the list
    /// that is there, in place, and no catalog action is read for it. Its person's first input reads the actions
    /// again with no ask of the row, in later frames.
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
            try #require(pages.count == 1, "the second key opened \(pages.count) New Tab pages")
            let view = try #require(tabs.views[pages[0]], "the second page has no view after two hand-overs")
            #expect(view.model.newTab?.omnibar.actions == web.list.actions,
                    "the second page has \(view.model.newTab?.omnibar.actions.count ?? 0) of the \(web.list.actions.count) actions")

            // The page's own report of its person's first input. The row asks for nothing: it is only the display.
            let frames = services.mainWork.frames
            try #require(!frames.activeClients.contains(Self.lister), "the lister has a task before the first input")
            _ = await view.model.respond(to: .touched)
            // The write of the page's flag only asks for the read, in the main queue's next turn: its own turn
            // queues no task of the lister.
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

    /// Two New Tab keys inside one frame (a large session has long frames): the older page is not its pane's
    /// selection at the next frame, so it has no view when the lister's first task runs. The two pages start no
    /// listing, and the older one takes the list, with no read, when its view is made.
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
            let pair = web.others()
            let unseen = pair.filter { tabs.views[$0] == nil }
            print("new-tab-list: two web pages in one frame: \(pair.count) pages, \(unseen.count) with no view; \(held.started - before.started) listings "
                + "started, \(held.actionsRead - before.actionsRead) catalog actions read again, \(handed.frames) + \(again.frames) frames with a lister "
                + "task; the focus context \(key) in the keys' turn, \(Self.focus(services)) now")
            #expect(held.started == before.started,
                    "the two pages started \(held.started - before.started) listings and read \(held.actionsRead - before.actionsRead) catalog actions again")
            try #require(pair.count == 2 && unseen.count == 1, "the fixture did not make the case: \(pair.count) pages, \(unseen.count) with no view")
            let newer = try #require(pair.compactMap { tabs.views[$0] }.first)
            #expect(newer.model.newTab?.omnibar.actions == web.list.actions,
                    "the page with a view has \(newer.model.newTab?.omnibar.actions.count ?? 0) of the \(web.list.actions.count) actions")

            // The person selects the older page: its view is made at the next frame.
            web.pane.select(CmuxNextTabs.TabID(unseen[0].key))
            let made = await Self.listed(services)
            let last = await Self.listed(services)
            let end = lister.counts
            let older = web.others().compactMap { tabs.views[$0] }.first { $0 !== newer }
            print("new-tab-list: the older page at its view's make: \(end.started - held.started) listings started, \(end.actionsRead - held.actionsRead) "
                + "catalog actions read again, \(made.frames) + \(last.frames) frames with a lister task")
            let view = try #require(older, "the older page has no view after it was selected")
            #expect(view.model.newTab?.omnibar.actions == web.list.actions,
                    "the older page has \(view.model.newTab?.omnibar.actions.count ?? 0) of the \(web.list.actions.count) actions")
            #expect(end.started == held.started,
                    "the older page started \(end.started - held.started) listings and read \(end.actionsRead - held.actionsRead) catalog actions again")
        }
    }

    // MARK: - A key from a terminal

    /// The focus contexts that the slices of one listing read under, in their order (one value while it holds).
    @MainActor private final class Slices { var contexts: [String] = [] }

    /// The first New Tab key from a terminal, as a person holds it there: the focus goes from the terminal to the
    /// page. One listing reads the page's list, each of its slices under the focus context that the page has at the
    /// hand-over, and the list is kept: a second ask starts no listing.
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
            let lister = services.newTabActions, tabs = services.agentTabs
            let known = Set(tabs.newTabPages.keys), before = lister.counts, start = Self.focus(services)
            NewTabPage.open(in: pane, seed: nil)
            // The row's ask joins the page's listing. A frame whose task reads a slice (the listing started, and its
            // last slice is not read) notes the focus context that the slice reads under.
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
            #expect(first.started == before.started + 1, "the first key from a terminal started \(first.started - before.started) listings")
            #expect(slices.contexts == [handed], "the listing's slices read under the focus contexts \(slices.contexts); the page has \(handed) at the hand-over")
            #expect(end.started == first.started, "a second ask started \(end.started - first.started) listings")
            let page = try #require(tabs.newTabPages.keys.first { !known.contains($0) }, "the key opened no New Tab page")
            let view = try #require(tabs.views[page], "the page has no view after its listing")
            #expect(cold.list != nil && view.model.newTab?.omnibar.actions == again.list?.actions, "the page does not show the list of now")
        }
    }

    /// What a web row starts from: an app with one web New Tab page, made cold, that has the palette's actions.
    @MainActor private struct Web {
        let services: AppServices
        let pane: PaneController
        /// The first page's view.
        let first: AgentPaneView
        /// The list the lister gives with the focus on the first page.
        let list: Listed
        /// The keys of the New Tab pages before the first one.
        let known: Set<AgentTabKey>

        /// The New Tab pages that came after the first one, by their keys of now (a key changes when the store answers).
        func others() -> [AgentTabKey] {
            let tabs = services.agentTabs
            return tabs.newTabPages.keys.filter { !known.contains($0) && tabs.views[$0] !== first }
        }
    }

    /// The registry's focus context, as a number for a print.
    private static func focus(_ services: AppServices) -> String { "\(services.registry.context.rawValue)" }

    /// Runs `body` in an app (with its own daemon) whose pane shows one web New Tab page that has the list. No page
    /// is prepared, so each page of the row is made cold, as the pages of a hold are.
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
            let known = Set(tabs.newTabPages.keys)
            let start = focus(services)
            NewTabPage.open(in: pane, seed: nil)
            let key = focus(services)
            let cold = await listed(services)
            let read = focus(services)
            // The focus goes to the page in its first frames. A second ask gives the list of that focus.
            let settled = await listed(services)
            let list = try #require(settled.list, "the first page's second ask never got a list")
            let page = try #require(tabs.newTabPages.keys.first { !known.contains($0) }, "Cmd-T opened no New Tab page")
            let first = try #require(tabs.views[page], "the first page has no view after its listing")
            try #require(!list.actions.isEmpty && first.model.newTab?.omnibar.actions.isEmpty == false, "the first page did not get a list")
            let counts = services.newTabActions.counts
            print("new-tab-list: the first web page: \(counts.started) listings started in two asks, \(cold.frames) + \(settled.frames) frames with a lister "
                + "task; the focus context \(start) before the key, \(key) in the key's turn, \(read) after the first hand-over, \(focus(services)) now")
            try await body(Web(services: services, pane: pane, first: first, list: list, known: known))
        }
    }

    // MARK: - The app

    @MainActor private struct App {
        let services: AppServices
        let pane: PaneController
        let close: @MainActor () -> Void
    }

    /// A window of this Mac with one pane, with the native New Tab page on.
    private static func shown() async throws -> App {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let directory = FileManager.default.temporaryDirectory.appending(path: "list-kept-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"tabs":{"nativeNewTabPage":true}}"#.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["list-kept-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        let close: @MainActor () -> Void = {
            services.newTabSpares.dropAll()
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            // The window's first content comes in a later turn. This wait is the fixture's, not a row's.
            try await PinnedPageTests.until({ controller.workspaceContent?.panes.count == 1 }, report: { "the window never showed the workspace's pane" })
            let content = try #require(controller.workspaceContent)
            content.contentView.layoutSubtreeIfNeeded()
            let window = try #require(controller.window)
            services.newTabSpares.retarget(window)
            let pane = try #require(content.panes.values.first)
            return App(services: services, pane: pane, close: close)
        } catch {
            close()
            throw error
        }
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "list-kept-ws"), name: "list", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "list-kept-ws"), index: 0)])
        return tree
    }

    /// Cmd-T with a page prepared: the page shows in the open's own turn. Returns the page's model.
    private static func openPage(_ app: App) throws -> NativeNewTabModel {
        let pool = app.services.newTabSpares
        pool.warmNative()
        let spare = try #require(pool.nativeSpare, "no native New Tab page was prepared")
        let model = try #require(spare.model, "the prepared page has no model")
        let key = try #require(NewTabPage.openNative(in: app.pane, reusingShown: false), "the native New Tab page is off")
        try #require(app.pane.currentTabKey == key, "Cmd-T did not show the prepared page in its own turn")
        return model
    }

    /// What one ask gave: the list (nil when no hand-over came), and the frames the lister had a task for.
    private struct Asked {
        var list: Listed?
        var frames: Int
    }

    /// The lister's frame queue, as the frame scheduler names its clients.
    private static let lister = "NewTab.paletteActions"

    /// The most frames with a lister task that a row fires for one ask. A listing reads one catalog action or more
    /// in each task, so it has at most as many tasks as the catalog has entries, and one to start, one to arrange
    /// and one to hand over. Four times that is far above any listing (ten times the largest cold listing of the
    /// runs so far, 315 tasks, at the least).
    private static func frameLimit(_ services: AppServices) -> Int {
        max(4 * (services.registry.entries.count + 3), 3150)
    }

    /// One waiter of the lister, as a page is one: its stream gets the list at the hand-over.
    private typealias Waiter = (lists: AsyncStream<Listed>, feed: AsyncStream<Listed>.Continuation)

    /// Asks for the list as a page does.
    private static func ask(_ services: AppServices) -> Waiter {
        let (lists, feed) = AsyncStream.makeStream(of: Listed.self)
        services.newTabActions.list(wanted: { true }) { list in
            feed.yield(list)
            feed.finish()
        }
        return (lists, feed)
    }

    /// Asks for the list as a page does, and is the display until the lister hands it over.
    private static func listed(_ services: AppServices, inFrame: @escaping @MainActor @Sendable () -> Void = {}) async -> Asked {
        await handOver(to: ask(services), services, inFrame: inFrame)
    }

    /// Is the display until the lister hands the list to `waiter`: one frame after another, with no clock. No
    /// hand-over in ``frameLimit(_:)`` frames with a lister task is an issue. `inFrame` runs before each frame
    /// that the lister has a task for.
    private static func handOver(to waiter: Waiter, _ services: AppServices, inFrame: @escaping @MainActor @Sendable () -> Void = {}) async -> Asked {
        let (lists, feed) = waiter
        let limit = frameLimit(services)
        // The row's display link: it ends only when the row cancels it.
        let frames = Task { @MainActor () -> Int in
            var working = 0
            while !Task.isCancelled {
                // Only a frame the lister has a task for counts. While the list's JSON is made off the main thread
                // the lister has none, and how many frames pass then is a matter of time, not of the listing.
                if services.mainWork.frames.activeClients.contains(lister) {
                    working += 1
                    if working == limit + 1 { feed.finish() }
                    inFrame()
                }
                services.mainWork.frameDidFire()
                // The JSON's hop back to the main thread runs here.
                await Task.yield()
            }
            return working
        }
        var got: Listed?
        for await list in lists { got = list }
        frames.cancel()
        let working = await frames.value
        if got == nil {
            let counts = services.newTabActions.counts
            Issue.record("no hand-over in \(working) frames with a lister task (the limit is \(limit)); listings started = \(counts.started)")
        }
        return Asked(list: got, frames: working)
    }

    /// Prints what one listing cost and what the catalog's rules read, for the record of a run.
    private static func report(_ what: String, _ counts: AgentPaneNewTabActions.Counts, frames: Int, of list: Listed, in services: AppServices) {
        let entries = services.registry.entries
        func bound(_ has: (CmuxNextActions.Action) -> Bool) -> Int { entries.filter { $0.action.map(has) ?? false }.count }
        let state = bound { $0.paletteState != nil }
        let title = bound { $0.paletteTitle != nil }
        let reason = bound { $0.paletteUnavailableReason != nil }
        let handler = bound { $0.unavailableReason != nil }
        let withRule = bound { $0.paletteState != nil || $0.paletteTitle != nil || $0.paletteUnavailableReason != nil || $0.unavailableReason != nil }
        let rules = "a palette state \(state), a palette title \(title), a palette reason \(reason), a reason of its handler \(handler), one or more of these \(withRule)"
        print("new-tab-list: \(what): \(counts.started) listings started, \(frames) frames with a lister task, \(counts.actionsRead) catalog actions read; "
            + "the catalog has \(entries.count) entries, \(entries.filter(\.isBound).count) with a handler; "
            + "the list has \(list.actions.count) rows in \(list.json.utf8.count) bytes of JSON; "
            + "actions with a rule that reads a state: \(rules)")
    }
}
