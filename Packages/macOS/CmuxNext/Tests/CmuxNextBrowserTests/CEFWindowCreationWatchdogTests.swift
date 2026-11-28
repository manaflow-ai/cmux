import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// NIGHTLY 1.0.0-nightly.4529584712101 (Leo, 2026-11-23 00:50Z): after a relaunch restored many Chromium tabs, one
/// showed "Can't open this page: The Chromium engine is not available in this build" and the pane later drew blank
/// with its tabs spinning. A Chromium window request that never answers left `CEFPaneHost.window` at `.creating` for
/// good, and a failed creation always showed the error page. A request unanswered past
/// `CEFPaneHost.windowCreationLimit` is now given up and its tabs retry once on a new window; the second failure
/// shows an error that names the real failure and the site (`CEFTab.CreationFailureSite`).
extension CEFSparePageSuites {
    @MainActor @Suite struct CEFWindowCreationWatchdogTests {
        typealias Fixture = CEFSparePageSuites.CEFSparePageTests

        private static func pendingHost(_ runtime: CEFRuntime) -> (CEFPaneHost, CEFTab) {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            host.endOfTurn = { $0() }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.present(tab, in: container)
            host.createDeferred()
            return (host, tab)
        }

        private static func settle(_ done: () -> Bool) async {
            for _ in 0..<40 where !done() { await Task.yield() }
        }

        @Test(arguments: [false, true])
        func anUnansweredRetryShowsTheRealFailure(firstRequestArrivesLate: Bool) async throws {
            let clock = ManualClock()
            let (runtime, root) = try Fixture.runtime(clock: clock)
            defer { Fixture.tearDown(runtime, root) }
            let (host, tab) = Self.pendingHost(runtime)
            #expect(host.isCreatingWindow && SpareSpy.createWindowCalls == 1)
            let firstRequest = try #require(runtime.pendingWindows.keys.first)

            try await clock.waitForSleeper()
            clock.advance(by: CEFPaneHost.windowCreationLimit + .seconds(1))
            await Self.settle { SpareSpy.createWindowCalls == 2 }
            #expect(SpareSpy.createWindowCalls == 2, "the tab asked for a new window once")
            #expect(host.isCreatingWindow, "the retry waits on its own request")
            #expect(tab.creationRetries == 1)

            try await clock.waitForSleeper()
            if firstRequestArrivesLate {
                runtime.handle(.afterCreated(browser: 10, request: firstRequest, window: 1))
                #expect(SpareSpy.closed.contains(10))
                #expect(tab.browserID == nil)
            }
            clock.advance(by: CEFPaneHost.windowCreationLimit + .seconds(1))
            await Self.settle { !host.isCreatingWindow }
            #expect(!host.isCreatingWindow, "the second silence ends the wait")
            #expect(SpareSpy.createWindowCalls == 2, "no third request")
            #expect(!tab.isCreationPending)
            let message = try #require(tab.state.loadError?.message)
            #expect(message.contains("windowTimeout"), "the error names the site: \(message)")
            #expect(!message.contains("not available in this build"), "the engine is up, so it does not say it is missing")
        }

        @Test func aWindowThatComesUpInTimeCancelsTheDeadline() async throws {
            let clock = ManualClock()
            let (runtime, root) = try Fixture.runtime(clock: clock)
            defer { Fixture.tearDown(runtime, root) }
            let (host, tab) = Self.pendingHost(runtime)
            SpareSpy.windows[10] = 1
            runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
            #expect(host.isLive && tab.browserID == 10)

            clock.advance(by: .seconds(60))
            for _ in 0..<20 { await Task.yield() }
            #expect(SpareSpy.createWindowCalls == 1, "no retry for a window that came up")
            #expect(host.isLive && tab.browserID == 10)
        }
    }
}
