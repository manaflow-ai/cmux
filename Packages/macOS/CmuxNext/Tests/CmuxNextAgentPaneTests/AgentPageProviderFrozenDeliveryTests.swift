import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// The agent page's host events through a real ``PageRouter`` hold. They are an
/// append-only transcript the page cannot read again, so while the page is hidden or frozen the
/// router keeps every one and sends them in `seq` order at release, with no gap and no drop; a busy
/// stream thaws the page at ``PageFrozenDelivery/orderedHalfFull`` and loses nothing.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentPageProviderFrozenDeliveryTests {
    private static func names(_ events: [JSONValue]) -> [String] {
        events.compactMap { $0["data"]?["value"]?.stringValue }
    }

    private static func seqs(_ events: [JSONValue]) -> [Double] {
        events.compactMap { $0["seq"]?.doubleValue }
    }

    /// A shown page with the stream live: subscribed through the router, and its first event
    /// delivered, so the provider's subscribe replay is done and later publishes reach the router.
    private static func livePage(_ provider: AgentPageProvider) async throws -> PageHoldHarness {
        let page = PageHoldHarness(descriptor: .agent, prefix: AgentPageOps.namespace, provider: provider)
        let reply = await page.subscribe(AgentPageProvider.hostEvents)
        try #require(reply["t"]?.stringValue == "ok", "\(reply)")
        #expect(provider.publish(.command("live")))
        await page.waitForEvents(1)
        return page
    }

    @Test func hostEventsWhileHiddenAllArriveInSeqOrder() async throws {
        let provider = AgentPageProvider(mainWork: AgentPaneMainThread.standalone().mainWork) { _ in nil }
        let page = try await Self.livePage(provider)
        page.router.holdDelivery()
        for name in ["turn-1", "tool-1", "turn-2"] {
            #expect(provider.publish(.command(name)))
        }
        #expect(page.events.count == 1, "nothing reaches a hidden page")
        #expect(page.router.heldEventCount == 3)

        page.router.releaseDelivery()
        let events = page.events
        #expect(Self.names(events) == ["live", "turn-1", "tool-1", "turn-2"])
        #expect(Self.seqs(events) == [1, 2, 3, 4])
        #expect(events.allSatisfy { $0["gap"] == nil })
        #expect(page.dropped.isEmpty)
        #expect(page.halfFullCount == 0)
    }

    /// More than half the provider's buffer while hidden: the page thaws once, before the batch it
    /// takes, stays hidden, and at release has every event in order.
    @Test func aBusyHiddenPageThawsAtHalfFullAndLosesNothing() async throws {
        let provider = AgentPageProvider(mainWork: AgentPaneMainThread.standalone().mainWork) { _ in nil }
        let page = try await Self.livePage(provider)
        let half = PageFrozenDelivery.orderedHalfFull
        let total = half + 10
        page.router.holdDelivery()
        var accepted = 0
        for n in 0..<total {
            if provider.publish(.command("e\(n)")) { accepted += 1 }
        }
        #expect(accepted == total, "the provider's own buffer never overflows")
        #expect(page.log == ["send:ev", "halfFull", "send:evs"], "the page thaws, then takes the batch")
        #expect(page.router.deliveryHeld, "the page stays hidden")
        #expect(page.router.heldEventCount == 10)
        #expect(page.events.count == 1 + half)

        page.router.releaseDelivery()
        let events = page.events
        #expect(Self.names(events) == ["live"] + (0..<total).map { "e\($0)" })
        #expect(Self.seqs(events) == (1...(total + 1)).map { Double($0) })
        #expect(events.allSatisfy { $0["gap"] == nil })
        #expect(page.dropped.isEmpty)
        #expect(page.halfFullCount == 1)
    }
}
