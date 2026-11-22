import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

extension CEFSparePageSuites {
    /// The spare page's close paths (#34252): every way the waiting page goes, and what each asks for.
    /// The stand-in shim and helpers are `CEFSparePageTests`' (`CEFSparePageFixture.swift`).
    @MainActor @Suite struct CEFSparePageCloseTests {
        typealias Rig = CEFSparePageTests
        typealias Count = CEFSparePageTests.Count

        /// The fork has no way to keep the spare page out of `chrome.tabs` and `chrome.windows`, so an
        /// extension can close it while it waits. The slot clears and asks for no new page: an extension
        /// that closes every blank tab would otherwise make one page each idle moment, without end
        /// (review of #34252 at b4b2abd2, item 3). The next Cmd-T joins with `tab_add`, as before the spare
        /// page, and it is the take that asks for the next page.
        @Test func anOutsideCloseOfTheWaitingPageAsksForNoNewPageUntilTheNextTake() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let (host, _, container) = try Rig.liveHost(runtime)
            let page = try Rig.spareWithPage(runtime)
            let needed = Count()
            runtime.spareWindow.onNeeded = { needed.value += 1 }

            runtime.handle(.beforeClose(browser: page))
            #expect(runtime.spareWindow.page == nil, "the slot clears")
            #expect(needed.value == 0, "a close cmux did not start asks for no new page")

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()
            #expect(SpareSpy.added.map(\.anchor) == [10], "joins with tab_add")
            #expect(SpareSpy.added.map(\.activate) == [1])
            #expect(link.browserID == SpareSpy.added.first?.browser && link.browserID != page)
            #expect(SpareSpy.moved.isEmpty && SpareSpy.closed.isEmpty, "nothing touches the closed page")
            #expect(host.lastActivated == link.browserID)
            #expect(needed.value == 1, "the take asks for the next page")
        }

        /// A pane takes the spare window for a hidden tab (an agent's background tab): the tab joins with
        /// `tab_add`, and on the next main-actor turn the window's placeholder closes and the page no tab
        /// took closes with it (`closeSparePlaceholder`), so no pane window keeps a tab nobody shows.
        @Test func aHiddenTabInATakenSpareWindowClosesTheUntakenPageOnTheNextTurn() async throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let page = try Rig.spareWithPage(runtime)
            let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
            host.endOfTurn = { $0() }
            let hidden = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(hidden)
            hidden.agentRelay.createBrowser()
            #expect(SpareSpy.added.map(\.anchor) == [20], "the hidden tab joins with tab_add")
            #expect(SpareSpy.closed.isEmpty, "nothing closes inside the join")

            for _ in 0..<20 where SpareSpy.closed.count < 2 { await Task.yield() }
            #expect(SpareSpy.closed.contains(page), "the untaken page closes")
            #expect(SpareSpy.closed.contains(20), "with the placeholder")
            #expect(runtime.spareWindow.page == nil)
        }

        /// The tab that took the spare window closes before it joined: the window is the spare again,
        /// still holding its page, which the next pane's new tab takes (`giveBack`).
        @Test func aTakenSpareWindowGivenBackKeepsItsPageForTheNextTab() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let page = try Rig.spareWithPage(runtime)
            let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
            let gone = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(gone)
            gone.close()
            #expect(runtime.spareWindow.host === host, "the spare again")
            #expect(runtime.spareWindow.page?.browser == page, "with its page")
            #expect(SpareSpy.closed.isEmpty)

            let next = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
            #expect(next === host)
            next.endOfTurn = { $0() }
            let tab = CEFTab(id: .random(), profile: .default, host: next, runtime: runtime)
            next.add(tab)
            next.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
            next.createDeferred()
            #expect(tab.browserID == page && SpareSpy.added.isEmpty, "the next tab takes the page with no tab_add")
        }

        /// The tab that took the spare window closes before it joined while another spare window was made
        /// meanwhile: the taken window has no use left and closes, its last tab and its page with it
        /// (`giveBack`, then `removed` with no tab left).
        @Test func aTakenSpareWindowGivenBackBesideANewSpareClosesItsPage() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let page = try Rig.spareWithPage(runtime)
            let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
            #expect(runtime.spareWindow.prepare(runtime: runtime), "a new spare window starts")
            let spare = try #require(runtime.spareWindow.host)
            let request = try #require(runtime.pendingWindows.first { $0.value === spare }?.key)
            SpareSpy.windows[21] = 3
            runtime.handle(.afterCreated(browser: 21, request: request, window: 3))
            #expect(runtime.spareWindow.page?.browser == page, "the old page waits in the taken window")

            let gone = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(gone)
            gone.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            #expect(SpareSpy.closed.contains(page), "the taken window's page closes")
            #expect(SpareSpy.closed.contains(20), "with its placeholder")
            #expect(runtime.spareWindow.page == nil)
        }

        /// Dropping the spare (`debug.cef drop_spare`) closes its waiting page too, and asks for none.
        @Test func droppingTheSpareClosesItsWaitingPage() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let page = try Rig.spareWithPage(runtime)
            let needed = Count()
            runtime.spareWindow.onNeeded = { needed.value += 1 }

            runtime.spareWindow.drop(runtime: runtime)
            #expect(SpareSpy.closed.contains(page), "the page closes")
            #expect(SpareSpy.closed.contains(20), "with the placeholder")
            #expect(runtime.spareWindow.page == nil && runtime.spareWindow.host == nil)
            #expect(needed.value == 0)
        }

        /// Quit closes every browser (`closeAll`), the waiting spare page among them: its close must not
        /// ask for a new page, which would arm the warmup's idle wait and timers in a quitting app
        /// (review of #34252, finding 1). The same close before quit does ask.
        @Test func theSparePageClosingAtQuitAsksForNoNewPage() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            _ = try Rig.liveHost(runtime)
            let page = try Rig.spareWithPage(runtime)
            let needed = Count()
            runtime.spareWindow.onNeeded = { needed.value += 1 }

            runtime.state = .shutDown
            runtime.handle(.beforeClose(browser: page))
            #expect(runtime.spareWindow.page == nil, "the slot clears")
            #expect(needed.value == 0, "a quitting app asks for no new spare page")
        }

        /// Only the spare page's own OnAfterCreated is kept from adoption: a tab Chromium makes itself in
        /// the spare window inside that `tab_add` (an extension's) still waits there for the first tab that
        /// takes the window (`CEFSpareWindow.park`), as before (review of #34252, finding 3).
        @Test func aChromiumTabMadeInsideTheSparePagesTabAddIsStillParked() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            #expect(runtime.spareWindow.prepare(runtime: runtime))
            let spare = try #require(runtime.spareWindow.host)
            let request = try #require(runtime.pendingWindows.first { $0.value === spare }?.key)
            SpareSpy.windows[20] = 2
            runtime.handle(.afterCreated(browser: 20, request: request, window: 2))
            SpareSpy.clearRecords()

            SpareSpy.chromiumTabInNextAdd = 77
            runtime.spareWindow.prepare(runtime: runtime)
            let page = try #require(SpareSpy.added.first?.browser)
            #expect(runtime.spareWindow.page?.browser == page)
            #expect(runtime.spareWindow.takeParked().map(\.browser) == [77], "Chromium's own tab is parked for the take")
        }

        /// The fork could not move the spare page into the pane's window: the page closes (no page
        /// lingers in the spare window as a tab nobody owns), and the tab joins with `tab_add`.
        @Test func aSparePageThatCannotMoveClosesAndTheTabFallsBackToTabAdd() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let (host, _, container) = try Rig.liveHost(runtime)
            let page = try Rig.spareWithPage(runtime)
            SpareSpy.moveAnswer = 0

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()

            #expect(SpareSpy.moved.map(\.browser) == [page], "it tried to move the page")
            #expect(SpareSpy.closed == [page], "the page that could not move closes")
            #expect(SpareSpy.added.map(\.anchor) == [10] && SpareSpy.added.map(\.activate) == [1], "the tab joins with tab_add")
            #expect(link.browserID == SpareSpy.added.first?.browser && link.browserID != page)
            #expect(host.lastActivated == link.browserID)
            #expect(runtime.spareWindow.page == nil)
        }

        /// The switch is turned off while a page waits (re-review of #34252 at 82b52979, optional): the next new
        /// tab joins with `tab_add` and the waiting page closes, so no frozen page is kept that nothing will take.
        @Test func aPageLeftWaitingWhenTheSwitchIsTurnedOffClosesAtTheNextNewTab() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let (host, _, container) = try Rig.liveHost(runtime)
            let page = try Rig.spareWithPage(runtime)
            Rig.setSparePage(false)

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()
            #expect(SpareSpy.added.map(\.anchor) == [10], "the tab joins with tab_add")
            #expect(SpareSpy.closed == [page], "the waiting page closes")
            #expect(runtime.spareWindow.page == nil)
        }
    }
}
