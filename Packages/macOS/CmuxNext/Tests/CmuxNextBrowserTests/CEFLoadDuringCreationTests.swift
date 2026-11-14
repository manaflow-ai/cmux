import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

extension CEFSparePageSuites {
    /// "I type in something and press Enter and if it's too early nothing happens" (Lawrence 2026-11-10).
    /// A pane's first Chromium window is created with the URL the tab had at that moment
    /// (`takeInitialURLString`). An address committed after that and before OnAfterCreated was only stored
    /// (`pendingURL`), and `attach` never read it again: Chromium showed the creation's page and the
    /// address bar went back to it. The stand-in shim and helpers are `CEFSparePageTests`'
    /// (`CEFSparePageFixture.swift`).
    @MainActor @Suite struct CEFLoadDuringCreationTests {
        typealias Rig = CEFSparePageTests

        static let later = URL(string: "https://example.org/typed")!

        /// A blank tab whose window is being created; Enter on an address loads it once the browser exists.
        @Test func anAddressCommittedWhileTheWindowIsCreatedLoads() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let (tab, request) = try creatingTab(runtime)
            #expect(SpareSpy.createdURLs.count == 1 && tab.browserID == nil)

            tab.load(Rig.address)
            #expect(SpareSpy.loads.isEmpty, "no browser yet: the load waits")

            runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
            #expect(tab.browserID == 7)
            #expect(SpareSpy.loads.map(\.url) == [Rig.address.absoluteString], "the committed address was never loaded")
            #expect(SpareSpy.loads.map(\.browser) == [7])
        }

        /// A tab created with one address; a second address committed before the browser exists wins, and only it
        /// is loaded after the creation's.
        @Test func aSecondAddressBeforeTheBrowserExistsReplacesTheFirst() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let (tab, request) = try creatingTab(runtime, first: Rig.address)
            #expect(SpareSpy.createdURLs == [Rig.address.absoluteString])

            tab.load(URL(string: "https://example.org/skipped")!)
            tab.load(Self.later)

            runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
            #expect(SpareSpy.loads.map(\.url) == [Self.later.absoluteString], "the last address committed is the page shown")
        }

        /// No address after creation: the creation's URL is the only navigation (no second load of it).
        @Test func aTabNotLoadedAgainNavigatesOnce() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let (tab, request) = try creatingTab(runtime, first: Rig.address)

            runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
            #expect(tab.browserID == 7)
            #expect(SpareSpy.loads.isEmpty, "the creation URL was loaded a second time")
        }

        /// A tab in a pane with no Chromium window yet, its window's creation started (not answered).
        private func creatingTab(_ runtime: CEFRuntime, first: URL? = nil) throws -> (CEFTab, Int32) {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            host.endOfTurn = { $0() }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            if let first { tab.load(first) }
            host.add(tab)
            host.present(tab, in: container)
            host.createDeferred()
            let request = try #require(runtime.pendingWindows.first { $0.value === host }?.key)
            SpareSpy.windows[7] = 1
            return (tab, request)
        }
    }
}
