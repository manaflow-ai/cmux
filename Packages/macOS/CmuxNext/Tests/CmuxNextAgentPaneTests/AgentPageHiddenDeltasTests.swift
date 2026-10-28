import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// A hidden chat that keeps streaming loses nothing. The acpmux transport's frames reach
/// the agent page through a real ``PageRouter`` hold (the page hidden or frozen); 20,000 of them all
/// arrive, in order and in `seq` order, with no gap and no drop, the page thawing for a batch each time
/// its `.ordered` stream fills half its bound.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentPageHiddenDeltasTests {
    @Test func twentyThousandDeltasWhileHiddenAllArriveIntact() async throws {
        let provider = AgentPageProvider(mainWork: AgentPaneMainThread.standalone().mainWork) { _ in nil }
        let page = PageHoldHarness(descriptor: .agent, prefix: AgentPageOps.namespace, provider: provider)
        let reply = await page.subscribe(AgentPageProvider.hostEvents)
        try #require(reply["t"]?.stringValue == "ok", "\(reply)")
        #expect(provider.publish(.command("live")))
        await page.waitForEvents(1)
        provider.transportDidOpen(1)

        let total = 20_000
        page.router.holdDelivery()
        var accepted = 0
        for n in 0..<total {
            let delta = AgentPaneTransportEvent(connection: 1, frames: ["{\"delta\":\(n)}"], closed: nil)
            if provider.publish(.transport(delta)) { accepted += 1 }
        }
        #expect(accepted == total, "the provider refused a delta while the page was hidden")
        #expect(page.router.deliveryHeld, "the page showed while it streamed hidden")
        page.router.releaseDelivery()

        let deltas = page.events.dropFirst()
        let frames = deltas.compactMap { $0["data"]?["value"]?["frames"]?.arrayValue?.first?.stringValue }
        #expect(frames == (0..<total).map { "{\"delta\":\($0)}" }, "the transcript's deltas came back out of order or incomplete")
        #expect(page.events.compactMap { $0["seq"]?.doubleValue } == (1...(total + 1)).map(Double.init))
        #expect(page.events.allSatisfy { $0["gap"] == nil }, "a delta was marked lost")
        #expect(page.dropped.isEmpty, "the router dropped a delta")
        #expect(page.halfFullCount == total / PageFrozenDelivery.orderedHalfFull)
    }
}
