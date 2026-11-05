import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

extension CEFSparePageSuites {
    /// HOT PATH AUDIT (browser): a new Chromium tab paid a synchronous `cmux_shim_tab_add` on the main
    /// thread (Chromium's UI thread): `cef.tab_add` p50 12.5 ms, p95 14-15 ms (fleet job b1bf9573,
    /// new_browser at 2 and 60 workspaces), 99 % of it Chromium's, before the page's first frame. So the
    /// page is made ahead, as Chrome on Android's WarmupManager makes a spare WebContents outside the
    /// tab model: one Chromium browser in the hidden spare window, made at an idle moment
    /// (`CEFSpareWindow.prepare`), that belongs to no tab until a new tab takes it. A tab that takes it
    /// makes no `tab_add` in its creation; the next one is made at the next idle moment, never in the
    /// creation's turn.
    @MainActor @Suite struct CEFSparePageTests {
        /// A link opens a tab in a pane whose Chromium window is live: the tab takes the spare page,
        /// which moves into the pane's window, joins as Chromium's active tab once, shows in layer
        /// hosting and loads the tab's address as its first navigation. No `tab_add`.
        @Test func aNewTabInALivePaneTakesTheSparePageWithNoTabAdd() throws {
            let (runtime, root) = try Self.runtime()
            defer { Self.tearDown(runtime, root) }
            let (host, _, container) = try Self.liveHost(runtime)
            let page = try Self.spareWithPage(runtime)

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            link.load(Self.address)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()

            #expect(SpareSpy.added.isEmpty, "no tab_add in the new tab's creation")
            #expect(link.browserID == page, "the tab's browser is the spare page")
            #expect(runtime.tabsByBrowser[page] === link)
            #expect(SpareSpy.moved.map(\.browser) == [page], "the spare page moves into the pane's window")
            #expect(SpareSpy.moved.map(\.anchor) == [10])
            #expect(SpareSpy.activated == [page], "made Chromium's active tab once")
            #expect(host.lastActivated == page, "its activation echo is this host's own")
            #expect(host.hostView.layerHosting.browser == page, "layer hosting follows the shown page")
            #expect(SpareSpy.loads.map(\.browser) == [page])
            #expect(SpareSpy.loads.map(\.url) == [Self.address.absoluteString], "the tab's address is the page's first navigation")
        }

        /// The pane's first Chromium tab takes the spare window (`CEFSpareWindow.take`): it takes the
        /// spare page already in that window. Nothing moves, no `tab_add`, no window is built.
        @Test func aTabInAPaneThatTookTheSpareWindowTakesItsSparePage() throws {
            let (runtime, root) = try Self.runtime()
            defer { Self.tearDown(runtime, root) }
            let page = try Self.spareWithPage(runtime)

            let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default)
            let host = runtime.host(for: key)
            #expect(host.key == key && host.isLive, "the pane took the live spare window")
            host.endOfTurn = { $0() }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            tab.load(Self.address)
            host.add(tab)
            host.present(tab, in: container)
            host.createDeferred()

            #expect(SpareSpy.added.isEmpty, "no tab_add in the new tab's creation")
            #expect(SpareSpy.createWindowCalls == 0, "no window is built")
            #expect(tab.browserID == page, "the tab's browser is the spare page")
            #expect(SpareSpy.moved.isEmpty, "the page is already in the window the pane took")
            #expect(SpareSpy.activated == [page], "made Chromium's active tab once")
            #expect(host.lastActivated == page)
            #expect(host.hostView.layerHosting.browser == page)
            #expect(SpareSpy.loads.map(\.url) == [Self.address.absoluteString])
            #expect(host.tabs.filter { $0 !== host.placeholder }.map(\.browserID) == [page], "the spare page is no tab of its own")
        }

        /// The take asks for the next spare page, and the next idle moment makes it in the spare
        /// window; the creation's own turn makes none. At most one untaken spare page.
        @Test func theNextSparePageIsMadeAtTheNextIdleMomentNotInTheCreation() throws {
            let (runtime, root) = try Self.runtime()
            defer { Self.tearDown(runtime, root) }
            let (host, _, container) = try Self.liveHost(runtime)
            let page = try Self.spareWithPage(runtime)
            let needed = Count()
            runtime.spareWindow.onNeeded = { needed.value += 1 }

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()

            #expect(link.browserID == page)
            #expect(needed.value == 1, "the take asks for the next spare page")
            #expect(SpareSpy.added.isEmpty, "the next spare page is not made in the creation's turn")

            // The warmup's next idle moment (`ChromiumWarmup` runs `CEFEngine.prepareSpareWindow`).
            runtime.spareWindow.prepare(runtime: runtime)
            #expect(SpareSpy.added.map(\.anchor) == [20], "made in the spare window")
            #expect(SpareSpy.added.map(\.activate) == [0])
            let next = SpareSpy.added.first?.browser ?? -1
            #expect(next != page && runtime.tabsByBrowser[next] == nil, "a new page that belongs to no tab")
            runtime.spareWindow.prepare(runtime: runtime)
            #expect(SpareSpy.added.count == 1, "at most one untaken spare page")
        }

        /// A tab that restores its history needs a browser with no committed entries of its own:
        /// it keeps today's `tab_add`, and the spare page waits for the next tab.
        @Test func aRestoringTabMakesItsOwnBrowserAndLeavesTheSparePage() throws {
            let (runtime, root) = try Self.runtime()
            defer { Self.tearDown(runtime, root) }
            let (host, _, container) = try Self.liveHost(runtime)
            let page = try Self.spareWithPage(runtime)

            let restored = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            restored.pendingRestore = "saved-navigation"
            host.add(restored)
            host.present(restored, in: container)
            host.createDeferred()

            #expect(SpareSpy.added.map(\.anchor) == [10], "joins the pane's window with tab_add")
            #expect(SpareSpy.added.map(\.url) == [""], "created empty for its restore")
            #expect(restored.browserID != page)
            #expect(SpareSpy.moved.isEmpty)
            #expect(runtime.tabsByBrowser[page] == nil, "the spare page waits for the next tab")
        }

        /// The waiting spare page is frozen as soon as it is made (no one sees it, so it must cost no
        /// frames or timers): through the renderer path on fork API 29, through DevTools when that path
        /// refuses it or the fork is older. A tab that takes it thaws it in the same turn, before it
        /// moves and shows, by the path that froze it.
        @Test(arguments: [FreezeCase(forkAPI: 27, rendererFreezes: true, viaDevTools: true),
                          FreezeCase(forkAPI: 29, rendererFreezes: true, viaDevTools: false),
                          FreezeCase(forkAPI: 29, rendererFreezes: false, viaDevTools: true)])
        func theWaitingSparePageIsFrozenAndATakeThawsItBeforeItShows(_ freeze: FreezeCase) throws {
            let (runtime, root) = try Self.runtime(forkAPI: freeze.forkAPI)
            defer { Self.tearDown(runtime, root) }
            let (host, _, container) = try Self.liveHost(runtime)
            SpareSpy.setFrozenAnswer = freeze.rendererFreezes ? 1 : 0
            let suffix = freeze.viaDevTools ? " devtools" : ""
            SpareSpy.clearRecords()
            #expect(runtime.spareWindow.prepare(runtime: runtime))
            let spare = try #require(runtime.spareWindow.host)
            let request = try #require(runtime.pendingWindows.first { $0.value === spare }?.key)
            SpareSpy.windows[20] = 2
            runtime.handle(.afterCreated(browser: 20, request: request, window: 2))
            SpareSpy.log = []
            runtime.spareWindow.prepare(runtime: runtime)
            let page = try #require(SpareSpy.added.first?.browser)
            #expect(SpareSpy.log == ["freeze \(page)\(suffix)"], "the waiting page is frozen when it is made")

            SpareSpy.log = []
            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            link.load(Self.address)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()

            #expect(link.browserID == page)
            #expect(SpareSpy.log == ["thaw \(page)\(suffix)", "move \(page)", "activate \(page)", "load \(page)"],
                    "thawed, then moved, shown and loaded in the take's turn")
            #expect(host.hostView.layerHosting.browser == page, "shown in the same turn")
        }

        /// Only a tab the person sees takes the spare page. A tab made hidden (an agent drives a
        /// background tab, `CEFAgentRelay.createBrowser`) and an agent-driven tab use `tab_add`, so
        /// automation never uses up the page that makes the person's next Cmd-T fast; that tab takes it.
        @Test func aHiddenOrAgentDrivenTabLeavesTheSparePageForThePersonsNextTab() throws {
            let (runtime, root) = try Self.runtime()
            defer { Self.tearDown(runtime, root) }
            let (host, _, container) = try Self.liveHost(runtime)
            let page = try Self.spareWithPage(runtime)

            let background = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(background)
            background.agentRelay.createBrowser()
            #expect(SpareSpy.added.map(\.anchor) == [10], "a hidden tab joins with tab_add")
            #expect(background.browserID != page)

            let agent = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            agent.isAgentDriven = true
            host.add(agent)
            host.present(agent, in: container)
            host.createDeferred()
            #expect(SpareSpy.added.map(\.anchor) == [10, 10], "an agent-driven tab joins with tab_add")
            #expect(agent.browserID != page)
            #expect(runtime.tabsByBrowser[page] == nil, "the spare page still waits")

            let person = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(person)
            host.present(person, in: container)
            host.createDeferred()
            #expect(person.browserID == page, "the person's tab takes it")
            #expect(SpareSpy.added.count == 2, "with no tab_add")
        }

        /// The take is behind the `browserPage.sparePage` Debug Setting (review of #34252 at b4b2abd2,
        /// item 1), on by default since its real-fork journey passed. Turned off, the spare window makes
        /// no page at all, and a new tab joins with `tab_add` as before.
        @Test func withTheSwitchOffNoSparePageIsMadeAndANewTabUsesTabAdd() throws {
            let (runtime, root) = try Self.runtime()
            defer { Self.tearDown(runtime, root) }
            let (host, _, container) = try Self.liveHost(runtime)
            Self.setSparePage(false)
            #expect(runtime.spareWindow.prepare(runtime: runtime), "the spare window still starts")
            let spare = try #require(runtime.spareWindow.host)
            let request = try #require(runtime.pendingWindows.first { $0.value === spare }?.key)
            SpareSpy.windows[20] = 2
            runtime.handle(.afterCreated(browser: 20, request: request, window: 2))
            SpareSpy.clearRecords()

            runtime.spareWindow.prepare(runtime: runtime)
            #expect(SpareSpy.added.isEmpty, "no spare page is made")
            #expect(runtime.spareWindow.page == nil)

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()
            #expect(SpareSpy.added.map(\.anchor) == [10], "the tab joins with tab_add")
            #expect(SpareSpy.moved.isEmpty)
        }

        /// The switch is on by default now that the real-fork journey `chromium-tab-takes-spare-page`
        /// passed (#34252's gate): with no Debug Settings override the spare window makes its page, and
        /// the next tab the person opens takes it with no `tab_add` (a link's first page skips Chromium's
        /// browser creation on the main thread).
        @Test func withNoOverrideTheSparePageIsMadeAndANewTabTakesIt() throws {
            let (runtime, root) = try Self.runtime()
            defer { Self.tearDown(runtime, root) }
            let (host, _, container) = try Self.liveHost(runtime)
            Self.setSparePage(nil) // no override: the default
            #expect(CEFSpareWindow.makesPages, "on by default")
            #expect(runtime.spareWindow.prepare(runtime: runtime))
            let spare = try #require(runtime.spareWindow.host)
            let request = try #require(runtime.pendingWindows.first { $0.value === spare }?.key)
            SpareSpy.windows[20] = 2
            runtime.handle(.afterCreated(browser: 20, request: request, window: 2))
            SpareSpy.clearRecords()

            runtime.spareWindow.prepare(runtime: runtime)
            #expect(SpareSpy.added.count == 1, "the spare page is made")
            let page = try #require(runtime.spareWindow.page?.browser)

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()
            #expect(link.browserID == page, "the person's tab takes it")
            #expect(SpareSpy.added.count == 1, "with no tab_add")
        }

        /// An extension can navigate the waiting page (`chrome.tabs.update`); its load events reach no
        /// tab. A page that started a load has history of its own: the take closes it and the tab joins
        /// with `tab_add` (review of #34252 at b4b2abd2, item 2).
        @Test func aWaitingPageThatLoadedIsClosedAtTheTakeAndTheTabUsesTabAdd() throws {
            let (runtime, root) = try Self.runtime()
            defer { Self.tearDown(runtime, root) }
            let (host, _, container) = try Self.liveHost(runtime)
            let page = try Self.spareWithPage(runtime)
            runtime.handle(.loadStart(browser: page, url: "https://extension.example/", fromPost: false))

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()
            #expect(SpareSpy.closed == [page], "the navigated page closes")
            #expect(SpareSpy.moved.isEmpty, "it is never moved into the pane")
            #expect(SpareSpy.added.map(\.anchor) == [10] && SpareSpy.added.map(\.activate) == [1], "the tab joins with tab_add")
            #expect(link.browserID != page && runtime.tabsByBrowser[page] == nil)
        }

        /// An extension can move the waiting page to another window (`chrome.tabs.move`): a page not in
        /// the window it was made in is closed at the take, and the tab joins with `tab_add`.
        @Test func aWaitingPageMovedToAnotherWindowIsClosedAtTheTakeAndTheTabUsesTabAdd() throws {
            let (runtime, root) = try Self.runtime()
            defer { Self.tearDown(runtime, root) }
            let (host, _, container) = try Self.liveHost(runtime)
            let page = try Self.spareWithPage(runtime)
            SpareSpy.windows[page] = 9

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()
            #expect(SpareSpy.closed == [page], "the moved page closes")
            #expect(SpareSpy.moved.isEmpty)
            #expect(SpareSpy.added.map(\.anchor) == [10], "the tab joins with tab_add")
            #expect(link.browserID != page && runtime.tabsByBrowser[page] == nil)
        }

        /// `debug.cef` reports the spare page (`spare_page`: `waiting` while one waits, else `none`) and
        /// how many a new tab took (`spare_pages_taken`), so a live check can see that a tab took it
        /// (re-review of #34252 at 82b52979, item 2). A page an extension navigated and that the take
        /// closed counts as no take.
        @Test func theSparePageStateReadsWaitingUntilATabTakesItAndCountsTheTake() throws {
            let (runtime, root) = try Self.runtime()
            defer { Self.tearDown(runtime, root) }
            let (host, _, container) = try Self.liveHost(runtime)
            #expect(runtime.spareWindow.pageState == "none" && runtime.spareWindow.pagesTaken == 0)
            let page = try Self.spareWithPage(runtime)
            #expect(runtime.spareWindow.pageState == "waiting", "a page waits")

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()
            #expect(link.browserID == page)
            #expect(runtime.spareWindow.pageState == "none", "taken")
            #expect(runtime.spareWindow.pagesTaken == 1, "one take")

            runtime.spareWindow.prepare(runtime: runtime)
            let next = try #require(SpareSpy.added.last?.browser)
            #expect(runtime.spareWindow.pageState == "waiting")
            runtime.handle(.loadStart(browser: next, url: "https://extension.example/", fromPost: false))
            let other = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(other)
            host.present(other, in: container)
            host.createDeferred()
            #expect(other.browserID != next, "the navigated page is not taken")
            #expect(runtime.spareWindow.pagesTaken == 1, "a refused page is no take")
        }

        /// Chromium's loading state alone (`.loadingState`, which a new browser reports with no load of its
        /// own) does not mark the waiting page as navigated: the next tab still takes it.
        @Test func aLoadingStateEventAloneLeavesTheWaitingPageTakeable() throws {
            let (runtime, root) = try Self.runtime()
            defer { Self.tearDown(runtime, root) }
            let (host, _, container) = try Self.liveHost(runtime)
            let page = try Self.spareWithPage(runtime)
            runtime.handle(.loadingState(browser: page, loading: false, canGoBack: false, canGoForward: false))

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()
            #expect(link.browserID == page, "the page is still taken")
            #expect(SpareSpy.added.isEmpty && SpareSpy.closed.isEmpty)
        }
    }
}
