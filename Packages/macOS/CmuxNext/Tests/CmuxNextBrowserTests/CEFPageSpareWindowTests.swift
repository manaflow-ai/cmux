import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

extension CEFSparePageSuites {
    /// The cmux pages' spare window (`CEFRuntime.pageSpareWindow`): each cmux page after the first joins a
    /// Chromium window made at an idle moment, so no page after the first calls `create_window` on its own
    /// open (relaunch to chat, item 6b: 80-160 ms per page from `create_window` to `first_window`). The
    /// stand-in shim and helpers are `CEFSparePageTests`' (`CEFSparePageFixture.swift`).
    @MainActor @Suite struct CEFPageSpareWindowTests {
        typealias Rig = CEFSparePageTests
        typealias Count = CEFSparePageTests.Count

        /// A page's pane key, as the App's page host makes it: its own pane, the pages' off-the-record profile.
        static func pageKey(_ profile: BrowserProfileID) -> CEFPaneKey {
            CEFPaneKey(pane: BrowserPaneID(rawValue: "cmux-page-" + UUID().uuidString), profile: profile, offTheRecord: true)
        }

        /// Chromium made the window `host` asked for: OnAfterCreated for `browser` in `window`.
        static func windowArrives(_ runtime: CEFRuntime, _ host: CEFPaneHost, browser: Int32, window: Int32) throws {
            let request = try #require(runtime.pendingWindows.first { $0.value === host }?.key)
            SpareSpy.windows[browser] = window
            runtime.handle(.afterCreated(browser: browser, request: request, window: window))
            #expect(host.isLive)
        }

        /// Opens a page the way the App's page host does (`makeTab`, then `createBrowser` before it shows).
        static func openPage(_ runtime: CEFRuntime, _ profile: BrowserProfileID) -> (CEFPaneHost, CEFTab) {
            let host = runtime.host(for: pageKey(profile))
            host.endOfTurn = { $0() }
            let tab = CEFTab(id: .random(), profile: profile, host: host, runtime: runtime)
            host.add(tab)
            tab.agentRelay.createBrowser()
            return (host, tab)
        }

        /// The first page builds its window; every later page takes the spare window made at the idle moment
        /// before it: across N pages the open itself never calls `create_window` again, nor `tab_add`
        /// (cmuxterm-hq#27488: it held main 2.0-4.6 s in Chromium's new-browser setup): each page takes the
        /// spare's placeholder browser, made with no URL, thaws it and loads its own address there.
        @Test func pagesAfterTheFirstJoinTheSpareWindowAndCreateNoWindow() async throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let profile = BrowserProfileID(rawValue: UUID())
            runtime.usePageSpareWindow(profile: profile)
            let pages = try #require(runtime.pageSpareWindow)
            defer { pages.drop(runtime: runtime) }
            let needed = Count()
            runtime.spareWindow.onNeeded = { needed.value += 1 }

            let (first, firstTab) = Self.openPage(runtime, profile)
            #expect(SpareSpy.createWindowCalls == 1, "the first page builds its own window")
            try Self.windowArrives(runtime, first, browser: 100, window: 50)
            #expect(firstTab.browserID == 100)
            #expect(needed.value >= 1, "the first page's window asks for the pages' spare")

            var openCreates: [Int] = []
            for index in 1...4 {
                needed.value = 0
                SpareSpy.createdURLs = []
                #expect(pages.prepare(runtime: runtime), "the idle moment makes the pages' spare window")
                let spare = try #require(pages.host)
                #expect(SpareSpy.createdURLs == [""], "its placeholder has no URL, so no history entry")
                #expect(spare.key.offTheRecord && spare.key.profile == profile, "of the pages' store")
                let placeholder = Int32(100 + index)
                try Self.windowArrives(runtime, spare, browser: placeholder, window: Int32(50 + index))
                #expect(needed.value >= 1, "its window coming up asks for the next idle moment")
                SpareSpy.clearRecords()

                let (host, tab) = Self.openPage(runtime, profile)
                openCreates.append(SpareSpy.createWindowCalls)
                #expect(host === spare, "page \(index + 1) takes the spare window")
                #expect(pages.host == nil, "which is no spare any more")
                #expect(SpareSpy.added.isEmpty, "no tab_add: no new browser on the open")
                #expect(tab.browserID == placeholder, "the page takes the placeholder's browser")
                #expect(runtime.tabsByBrowser[placeholder] === tab)
                #expect(host.placeholder == nil && !host.adoptablePlaceholder)
                let thaw = SpareSpy.log.firstIndex(of: "thaw \(placeholder) devtools")
                #expect(thaw != nil, "the frozen placeholder thaws")
                if let load = SpareSpy.log.firstIndex(of: "load \(placeholder)") { #expect(thaw.map { $0 < load } == true) }
                #expect(SpareSpy.loads.allSatisfy { $0.browser == placeholder }, "its address loads in that browser")
                for _ in 0..<20 { await Task.yield() }
                #expect(!SpareSpy.closed.contains(placeholder), "the page's browser stays open")
                #expect(host.tabs.map(\.id) == [tab.id], "the window holds the page alone")
            }
            #expect(openCreates == [0, 0, 0, 0], "no page after the first calls create_window on its open")
        }

        /// The security split: the pages' spare window is of the pages' store only. A web tab of the
        /// default profile, an incognito window's profile, or a remote machine's store never takes it,
        /// and a page never takes the web tabs' spare.
        @Test func thePagesSpareIsNeverAWebTabsAndTheWebSpareNeverAPages() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let profile = BrowserProfileID(rawValue: UUID())
            runtime.usePageSpareWindow(profile: profile)
            let pages = try #require(runtime.pageSpareWindow)
            defer { pages.drop(runtime: runtime) }

            #expect(pages.prepare(runtime: runtime))
            let pageSpare = try #require(pages.host)
            try Self.windowArrives(runtime, pageSpare, browser: 101, window: 51)
            #expect(pageSpare.isSpare)

            let web = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
            #expect(web !== pageSpare, "a web tab builds its own window")
            let incognito = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString),
                                                         profile: BrowserProfileID(rawValue: UUID()), offTheRecord: true))
            #expect(incognito !== pageSpare, "an incognito window's profile does not take it")
            var remote = Self.pageKey(profile)
            remote.machineKey = "remote"
            #expect(runtime.host(for: remote) !== pageSpare, "nor a remote machine's store")
            #expect(pages.host === pageSpare, "still the pages' spare")

            #expect(runtime.spareWindow.prepare(runtime: runtime), "the web tabs' spare")
            let webSpare = try #require(runtime.spareWindow.host)
            try Self.windowArrives(runtime, webSpare, browser: 102, window: 52)
            let (pageHost, _) = Self.openPage(runtime, profile)
            #expect(pageHost === pageSpare, "a page takes the pages' spare")
            #expect(runtime.spareWindow.host === webSpare, "never the web tabs' one")
            #expect(SpareSpy.added.isEmpty, "the page takes the pages' placeholder browser")
            #expect(pageHost.tabs.first?.browserID == 101)
        }

        /// A page whose open ended before it joined (it closed): the window is the pages' spare again,
        /// for the next page, as the web tabs' spare is given back (`giveBack`).
        @Test func aPageClosedBeforeItJoinedGivesTheSpareBack() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let profile = BrowserProfileID(rawValue: UUID())
            runtime.usePageSpareWindow(profile: profile)
            let pages = try #require(runtime.pageSpareWindow)
            defer { pages.drop(runtime: runtime) }
            #expect(pages.prepare(runtime: runtime))
            let spare = try #require(pages.host)

            let host = runtime.host(for: Self.pageKey(profile))
            #expect(host === spare)
            let gone = CEFTab(id: .random(), profile: profile, host: host, runtime: runtime)
            host.add(gone)
            gone.close()
            #expect(pages.host === spare, "the pages' spare again")
            #expect(runtime.host(for: Self.pageKey(profile)) === spare, "and the next page takes it")
        }
    }
}
