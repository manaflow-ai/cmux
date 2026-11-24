import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

extension CEFSparePageSuites {
    /// "why are they all stuck in loading state this is super bad" (Lawrence, 2026-11-23): nearly every background
    /// tab of a pane spun its loading throbber forever. The App makes a Chromium tab's page before any pane shows
    /// it: a rest of the pointer on a tab loads it ahead (`PaneController.loadOnHover`), hibernation restores a page
    /// in the background, an agent reads a tab's state. Each page got its address through `load`, which started a
    /// navigation (phase `.provisional`) at once, but Chromium makes a tab's browser only when a pane shows it
    /// (`CEFPaneHost.present`) or an agent asks for one (`CEFAgentRelay.createBrowser`). No Chromium load ever began
    /// for it, so none ever ended: the tab read as loading, and the strip spun an endless indicator for it. Chromium
    /// draws a tab it has not loaded yet with its favicon; its load starts when its browser is made.
    /// The stand-in shim and helpers are `CEFSparePageTests'` (`CEFSparePageFixture.swift`).
    @MainActor @Suite struct CEFUnshownTabLoadingTests {
        typealias Rig = CEFSparePageTests

        /// A page made before any pane shows it is not loading: it has its address, and no Chromium load runs.
        @Test func aPageNoPaneShowsIsNotLoading() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let (_, tab) = unshownTab(runtime)

            tab.load(Rig.address)

            #expect(tab.browserID == nil && SpareSpy.createdURLs.isEmpty, "no Chromium browser for a page no pane shows")
            #expect(!tab.state.isLoading, "a page Chromium has not begun to load read as loading: an endless throbber")
            #expect(!tab.state.isWaiting)
            #expect(tab.state.url == Rig.address, "the page keeps the address it will load")
        }

        /// The page's load starts in the turn a pane shows it (the throbber and Stop are on screen with the page),
        /// Chromium's browser is made with its address, and Chromium's load end ends it.
        @Test func itsLoadStartsWhenAPaneShowsItAndEndsWithChromiums() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let (host, tab) = unshownTab(runtime)
            tab.load(Rig.address)

            host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
            #expect(tab.state.isLoading, "a shown page loads from its first frame")
            #expect(tab.state.url == Rig.address)

            host.createDeferred()
            #expect(SpareSpy.createdURLs == [Rig.address.absoluteString], "Chromium's browser is made with the page's address")
            finishLoad(of: tab, runtime: runtime, request: try #require(runtime.pendingWindows.first { $0.value === host }?.key))
            #expect(!tab.state.isLoading, "Chromium's load end ends the tab's load")
            #expect(tab.state.phase == .finished)
        }

        /// An agent's background browser (`ensureCreated`, no pane shows it) starts the load it was made for.
        @Test func aBrowserMadeInTheBackgroundStartsTheLoad() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let (host, tab) = unshownTab(runtime)
            tab.load(Rig.address)

            _ = host.ensureCreated(tab)
            #expect(SpareSpy.createdURLs == [Rig.address.absoluteString])
            #expect(tab.state.isLoading, "the browser on its way loads the page")
            finishLoad(of: tab, runtime: runtime, request: try #require(runtime.pendingWindows.first { $0.value === host }?.key))
            #expect(!tab.state.isLoading)
        }

        /// A tab made by `CEFEngine` before a pane names itself: a host of its own, no window, never presented.
        private func unshownTab(_ runtime: CEFRuntime) -> (CEFPaneHost, CEFTab) {
            let id = BrowserTabID.random()
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: CEFPaneHost.ownTabPrefix + id.rawValue), profile: .default),
                                   runtime: runtime)
            host.endOfTurn = { $0() }
            let tab = CEFTab(id: id, profile: .default, host: host, runtime: runtime)
            host.add(tab)
            return (host, tab)
        }

        /// Chromium creates the browser (7) of window request `request`, then loads the page and stops loading.
        private func finishLoad(of tab: CEFTab, runtime: CEFRuntime, request: Int32) {
            SpareSpy.windows[7] = 1
            runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
            #expect(tab.browserID == 7)
            let url = Rig.address.absoluteString
            runtime.handle(CEFShimEvent(kind: 7, browser: 7, request: 0, a: 1, b: 0, s1: url, s2: "")) // loading
            runtime.handle(CEFShimEvent(kind: 8, browser: 7, request: 0, a: 0, b: 0, s1: url, s2: "")) // load start (commit)
            runtime.handle(CEFShimEvent(kind: 9, browser: 7, request: 0, a: 200, b: 0, s1: "", s2: "")) // load end
            runtime.handle(CEFShimEvent(kind: 7, browser: 7, request: 0, a: 0, b: 0, s1: url, s2: "")) // loading stopped
        }
    }
}
