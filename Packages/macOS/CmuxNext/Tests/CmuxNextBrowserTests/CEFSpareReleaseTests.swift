import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

extension CEFSparePageSuites {
    /// The web tabs' spare window and spare page exist only while a web page is live or likely
    /// (`CEFSpareWindow.webPagesChanged`). With 500 hibernated web tabs the fleet infinite-tabs bench showed
    /// both still up, two renderers that host no page, about +214 MB RSS / +53 MB footprint over an empty
    /// app. Once no web page is live for `CEFSpareWindow.releaseQuiet`, both close; a web page coming live,
    /// or a reach for one, makes them again. The cmux pages' spare stays. The stand-in shim and helpers
    /// are `CEFSparePageTests`' (`CEFSparePageFixture.swift`).
    @MainActor @Suite struct CEFSpareReleaseTests {
        typealias Rig = CEFSparePageTests
        typealias Count = CEFSparePageTests.Count
        typealias Pages = CEFPageSpareWindowTests

        /// The live pane's page (browser 10) hibernates: Chromium closes its browser, its tab leaves the pane.
        static func hibernate(_ runtime: CEFRuntime, browser: Int32 = 10) {
            runtime.handle(.beforeClose(browser: browser))
            #expect(runtime.tabsByBrowser[browser] == nil)
        }

        /// A tab is shown in `host`, whose window closed with its last tab (a hibernated tab waking, or a new
        /// tab there): it builds its window, which comes up as `browser` in `window`.
        static func showBuildingItsWindow(_ runtime: CEFRuntime, _ host: CEFPaneHost, browser: Int32, window: Int32,
                                          restores: Bool = false) throws -> CEFTab {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            if restores { tab.pendingRestore = "saved-navigation" }
            host.add(tab)
            host.present(tab, in: container)
            host.createDeferred()
            let request = try #require(runtime.pendingWindows.first { $0.value === host }?.key, "the tab builds its own window")
            SpareSpy.windows[browser] = window
            runtime.handle(.afterCreated(browser: browser, request: request, window: window))
            #expect(host.isLive && tab.browserID == browser, "the tab is live")
            return tab
        }

        /// Lets the release deadline's task run once the clock passed it.
        static func settle() async {
            for _ in 0..<20 { await Task.yield() }
        }

        /// (1) Every web page hibernates: the quiet period starts, and when it ends the spare window's
        /// placeholder and the spare page close, and no idle moment makes them again.
        @Test func afterTheQuietPeriodWithEveryWebPageAsleepTheSpareWindowAndPageClose() async throws {
            let clock = ManualClock()
            let (runtime, root) = try Rig.runtime(clock: clock)
            defer { Rig.tearDown(runtime, root) }
            _ = try Rig.liveHost(runtime)
            let page = try Rig.spareWithPage(runtime)
            let needed = Count()
            runtime.spareWindow.onNeeded = { needed.value += 1 }
            #expect(runtime.spareWindow.releaseState == "held", "a live web page holds them")

            Self.hibernate(runtime)
            #expect(runtime.spareWindow.releaseState == "pending")
            try await clock.waitForSleeper()
            clock.advance(by: CEFSpareWindow.releaseQuiet - .seconds(1))
            await Self.settle()
            #expect(!SpareSpy.closed.contains(20) && !SpareSpy.closed.contains(page), "nothing closes before the quiet period ends")

            clock.advance(by: .seconds(1))
            for _ in 0..<20 where !SpareSpy.closed.contains(20) { await Task.yield() }
            #expect(SpareSpy.closed.contains(page), "the spare page closes")
            #expect(SpareSpy.closed.contains(20), "the spare window's placeholder closes, and its window with it")
            #expect(runtime.spareWindow.host == nil && runtime.spareWindow.page == nil)
            #expect(runtime.spareWindow.releaseState == "released")

            SpareSpy.clearRecords()
            #expect(!runtime.spareWindow.prepare(runtime: runtime), "no idle moment makes them while no web page is live")
            #expect(SpareSpy.createWindowCalls == 0 && SpareSpy.added.isEmpty)
            #expect(needed.value == 0, "the release asks for no spare")
        }

        /// (2) A web page comes live again before the quiet period ends: the release is called off, so the
        /// spare window and page stay, with no close and remake.
        @Test func aWebPageLiveBeforeTheQuietPeriodEndsKeepsThemWithNoChurn() async throws {
            let clock = ManualClock()
            let (runtime, root) = try Rig.runtime(clock: clock)
            defer { Rig.tearDown(runtime, root) }
            let (host, _, _) = try Rig.liveHost(runtime)
            let page = try Rig.spareWithPage(runtime)
            let spare = try #require(runtime.spareWindow.host)

            Self.hibernate(runtime)
            try await clock.waitForSleeper()
            clock.advance(by: .seconds(30))
            await Self.settle()
            _ = try Self.showBuildingItsWindow(runtime, host, browser: 11, window: 3)
            #expect(runtime.spareWindow.releaseState == "held", "a live web page calls the release off")

            clock.advance(by: CEFSpareWindow.releaseQuiet * 2)
            await Self.settle()
            #expect(!SpareSpy.closed.contains(20) && !SpareSpy.closed.contains(page), "nothing closes")
            #expect(runtime.spareWindow.host === spare && runtime.spareWindow.page?.browser == page, "the same spare window and page")
            #expect(SpareSpy.createWindowCalls == 1, "only the woken tab's own window is built")
        }

        /// (3) After the release a hibernated tab wakes, or a new web tab opens in a new pane: it builds its own
        /// window (as a pane whose window closed does) and is live, and its page coming live asks for the spare
        /// again, which the next idle moment makes.
        @Test(arguments: ["wake", "restore", "new pane"])
        func afterTheReleaseAWebTabIsLiveAndTheSpareIsMadeAgain(_ how: String) async throws {
            let clock = ManualClock()
            let (runtime, root) = try Rig.runtime(clock: clock)
            defer { Rig.tearDown(runtime, root) }
            let (host, _, _) = try Rig.liveHost(runtime)
            _ = try Rig.spareWithPage(runtime)
            let needed = Count()
            runtime.spareWindow.onNeeded = { needed.value += 1 }
            Self.hibernate(runtime)
            try await clock.waitForSleeper()
            clock.advance(by: CEFSpareWindow.releaseQuiet)
            for _ in 0..<20 where runtime.spareWindow.releaseState != "released" { await Task.yield() }
            #expect(runtime.spareWindow.releaseState == "released")
            SpareSpy.clearRecords()

            let target = how == "new pane"
                ? runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default)) : host
            target.endOfTurn = { $0() }
            let tab = try Self.showBuildingItsWindow(runtime, target, browser: 12, window: 4, restores: how == "restore")
            #expect(SpareSpy.createWindowCalls == 1, "the tab builds its own window")
            #expect(runtime.tabsByBrowser[12] === tab)
            #expect(runtime.spareWindow.releaseState == "held")
            #expect(needed.value >= 1, "its page coming live asks for the spare again")

            #expect(runtime.spareWindow.prepare(runtime: runtime), "the next idle moment makes the spare window")
            let spare = try #require(runtime.spareWindow.host)
            #expect(SpareSpy.createWindowCalls == 2)
            let request = try #require(runtime.pendingWindows.first { $0.value === spare }?.key)
            SpareSpy.windows[21] = 5
            runtime.handle(.afterCreated(browser: 21, request: request, window: 5))
            runtime.spareWindow.prepare(runtime: runtime)
            #expect(runtime.spareWindow.pageState == "waiting", "and then its spare page")
        }

        /// (3) The warmup's reach for a web tab (the "+" engine menu, the palette) asks for a released spare
        /// again; made and not used, it closes after the next quiet period.
        @Test func aReachForAWebTabMakesTheReleasedSpareAgain() async throws {
            let clock = ManualClock()
            let (runtime, root) = try Rig.runtime(clock: clock)
            defer { Rig.tearDown(runtime, root) }
            _ = try Rig.liveHost(runtime)
            _ = try Rig.spareWithPage(runtime)
            let needed = Count()
            runtime.spareWindow.onNeeded = { needed.value += 1 }
            Self.hibernate(runtime)
            try await clock.waitForSleeper()
            clock.advance(by: CEFSpareWindow.releaseQuiet)
            for _ in 0..<20 where runtime.spareWindow.releaseState != "released" { await Task.yield() }

            runtime.spareWindow.webPageLikely(runtime: runtime)
            #expect(needed.value == 1, "the reach asks for the spare")
            #expect(runtime.spareWindow.prepare(runtime: runtime))
            let spare = try #require(runtime.spareWindow.host)
            let request = try #require(runtime.pendingWindows.first { $0.value === spare }?.key)
            SpareSpy.windows[22] = 6
            runtime.handle(.afterCreated(browser: 22, request: request, window: 6))
            #expect(runtime.spareWindow.releaseState == "pending", "no web page came: the quiet period runs again")
            try await clock.waitForSleeper()
            clock.advance(by: CEFSpareWindow.releaseQuiet)
            for _ in 0..<20 where !SpareSpy.closed.contains(22) { await Task.yield() }
            #expect(SpareSpy.closed.contains(22) && runtime.spareWindow.releaseState == "released")
        }

        /// (4) The cmux pages' spare window is never released: a live cmux page is no web page, and the web
        /// spare's release leaves the pages' spare window and its placeholder up.
        @Test func theCmuxPagesSpareIsUntouched() async throws {
            let clock = ManualClock()
            let (runtime, root) = try Rig.runtime(clock: clock)
            defer { Rig.tearDown(runtime, root) }
            let profile = BrowserProfileID(rawValue: UUID())
            runtime.usePageSpareWindow(profile: profile)
            let pages = try #require(runtime.pageSpareWindow)
            defer { pages.drop(runtime: runtime) }
            _ = try Rig.liveHost(runtime)
            let page = try Rig.spareWithPage(runtime)
            let (pageHost, pageTab) = Pages.openPage(runtime, profile)
            try Pages.windowArrives(runtime, pageHost, browser: 100, window: 50)
            #expect(pageTab.browserID == 100)
            #expect(pages.prepare(runtime: runtime))
            let pagesSpare = try #require(pages.host)
            try Pages.windowArrives(runtime, pagesSpare, browser: 101, window: 51)
            SpareSpy.clearRecords()

            Self.hibernate(runtime)
            #expect(runtime.spareWindow.releaseState == "pending", "a live cmux page is no web page")
            #expect(pages.releaseState == "held")
            try await clock.waitForSleeper()
            clock.advance(by: CEFSpareWindow.releaseQuiet)
            for _ in 0..<20 where !SpareSpy.closed.contains(20) { await Task.yield() }
            #expect(SpareSpy.closed.contains(20) && SpareSpy.closed.contains(page), "the web spare is released")
            #expect(!SpareSpy.closed.contains(100) && !SpareSpy.closed.contains(101), "no cmux page browser closes")
            #expect(pages.host === pagesSpare && pagesSpare.isLive && pagesSpare.placeholder?.browserID == 101,
                    "the pages' spare window stays up")
            #expect(pages.releaseState == "held")
            #expect(runtime.tabsByBrowser[100] === pageTab, "the cmux page stays live")
        }
    }
}
