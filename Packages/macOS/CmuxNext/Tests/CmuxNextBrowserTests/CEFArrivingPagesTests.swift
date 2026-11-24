import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

extension CEFSparePageSuites {
    /// The page a link opens counts as arriving until its document may take keys, and the next spare waits for it
    /// (`CEFArrivingPages`, `ChromiumWarmup`). Under load, link_right's next spare window and spare page were made in
    /// the link's own load (fleet step a949d677 at 4891646d: `cef.create_window` 260-600 ms and `cef.spare_page`
    /// 1.0-1.5 s after the click), and 4 of 10 pages had not painted after 5 s (Leo 2026-11-05: "it takes EGREGIOUSLY
    /// long for me to open up a link/the pane on the right opens"). The stand-in shim and helpers are
    /// `CEFSparePageTests`' (`CEFSparePageFixture.swift`).
    @MainActor @Suite struct CEFArrivingPagesTests {
        typealias Rig = CEFSparePageTests
        typealias Count = CEFSparePageTests.Count

        /// A link the person opens arrives once its document loaded and painted: until then the warmup's next spare
        /// waits, and its arrival tells the warmup.
        @Test func aShownLinkArrivesWhenItsDocumentMayTakeKeys() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let (host, _, container) = try Rig.liveHost(runtime)
            _ = try Rig.spareWithPage(runtime)
            let settled = Count()
            runtime.arriving.onSettled = { settled.value += 1 }
            #expect(runtime.arriving.isEmpty, "the pane's own page arrived before the test")

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            link.load(Rig.address)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()

            #expect(link.browserID != nil)
            #expect(!runtime.arriving.isEmpty, "the link's page is arriving: the next spare waits")
            #expect(settled.value == 0)
            link.documentArrived()
            #expect(runtime.arriving.isEmpty, "its document may take keys: the next spare may be made")
            #expect(settled.value == 1, "the warmup hears it once")
            link.documentArrived()
            #expect(settled.value == 1)
        }

        /// A link closed before its page arrived holds the warmup no longer.
        @Test func aLinkClosedBeforeItArrivedEndsItsWait() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let (host, _, container) = try Rig.liveHost(runtime)
            let settled = Count()
            runtime.arriving.onSettled = { settled.value += 1 }

            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            link.load(Rig.address)
            host.add(link)
            host.present(link, in: container)
            host.createDeferred()
            #expect(!runtime.arriving.isEmpty)

            link.close()
            #expect(runtime.arriving.isEmpty)
            #expect(settled.value == 1)
        }

        /// A page nobody waits for (an agent's, or a hidden tab's) never holds the next spare back.
        @Test func anAgentDrivenOrHiddenTabIsNoArrival() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            let (host, _, container) = try Rig.liveHost(runtime)

            let hidden = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            hidden.load(Rig.address)
            host.add(hidden)
            hidden.agentRelay.createBrowser()
            #expect(hidden.browserID != nil)

            let agent = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            agent.isAgentDriven = true
            agent.load(Rig.address)
            host.add(agent)
            host.present(agent, in: container)
            host.createDeferred()
            #expect(agent.browserID != nil)

            #expect(runtime.arriving.isEmpty)
        }

        /// A page that never paints counts for the limit only, so the warmup is never held for good.
        @Test func aPageThatNeverArrivesStopsCountingAtTheLimit() async throws {
            let pages = CEFArrivingPages(limit: .milliseconds(20))
            let settled = Count()
            pages.onSettled = { settled.value += 1 }
            pages.began(.random())
            #expect(!pages.isEmpty)
            for _ in 0..<200 where !pages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            #expect(pages.isEmpty)
            #expect(settled.value == 1)
        }
    }
}
