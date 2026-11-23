import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// A pane whose pages all closed or hibernated keeps no Chromium host. The runtime kept every pane's
/// `CEFPaneHost` (and its `CEFHostView` with its layers) after the pane's last page went: on the fleet bench
/// (500 browser tabs in 200 workspaces, all hibernated) the app held 303 `CEFHostView`s for about 4 live
/// pages. Against the spare page suites' stand-in shim.
extension CEFSparePageSuites {
    @MainActor @Suite struct CEFEmptyPaneHostTests {
        typealias Fixture = CEFSparePageSuites.CEFSparePageTests

        /// A pane's host made through the runtime, showing one live page (browser 10, window 1).
        private static func paneHost(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab, NSView) {
            let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
            host.endOfTurn = { $0() }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(first)
            host.present(first, in: container)
            host.createDeferred()
            SpareSpy.windows[10] = 1
            runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
            try #require(host.isLive && first.browserID == 10)
            return (host, first, container)
        }

        @Test func aPaneWhoseLastPageWentKeepsNoHostAndItsNextPageGetsAFreshOne() throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            Fixture.setSparePage(false)
            let (host, first, _) = try Self.paneHost(runtime)
            let key = host.key
            try #require(runtime.hosts[key] === host)

            // The page hibernates or closes: Chromium destroyed its browser.
            first.browserDidClose(closesTab: false)

            #expect(runtime.hosts[key] == nil, "the runtime let the empty host go")
            #expect(host.hostView.superview == nil, "its host view left the pane")
            let next = runtime.host(for: key)
            #expect(next !== host, "the pane's next page makes a fresh host")
            #expect(runtime.hosts[key] === next)
        }

        @Test func aPaneWithAnotherPageKeepsItsHost() throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            Fixture.setSparePage(false)
            let (host, first, _) = try Self.paneHost(runtime)
            let second = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(second)
            host.ensureCreated(second)
            try #require(second.browserID != nil)

            first.browserDidClose(closesTab: false)

            #expect(runtime.hosts[host.key] === host, "a host that still has a page stays")
        }
    }
}
