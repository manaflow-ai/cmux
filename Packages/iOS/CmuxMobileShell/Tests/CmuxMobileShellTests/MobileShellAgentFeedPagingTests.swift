@testable import CmuxMobileShell
import CmuxMobileShellModel
import Testing

@MainActor
@Suite("Mobile shell agent feed paging")
struct MobileShellAgentFeedPagingTests {
    @Test("Phone retention limit removes paging and prevents another request")
    func retentionLimitStopsRequests() async throws {
        let store = MobileShellComposite()
        let router = RoutingHostRouter()
        await router.setWorkstreamFeedTotalCount(2_400)
        try installSecondaryClient(
            on: store,
            macDeviceID: "feed-mac",
            router: router,
            supportedHostCapabilities: [MobileShellComposite.agentFeedCapability]
        )
        let client = try #require(store.secondaryMacSubscriptions["feed-mac".pairingKey]?.client)
        defer { Task { await client.disconnect() } }

        await store.refreshAgentFeed()
        while store.agentFeedCanLoadOlder {
            await store.loadOlderAgentFeed()
        }

        let cursors = await router.recordedWorkstreamFeedListCursors()
        #expect(cursors.count == 7)
        #expect(cursors.map { $0 ?? "newest" } == [
            "newest", "2100", "1800", "1500", "1200", "900", "600",
        ])
        #expect(store.agentFeedItems.count == MobileAgentFeedAggregation.maxItemCount)
        #expect(Set(store.agentFeedItems.map(\.id)).count == MobileAgentFeedAggregation.maxItemCount)
        #expect(!store.agentFeedHasMoreItems)
        #expect(!store.agentFeedCanLoadOlder)
        #expect(store.agentFeedSnapshotsByMac.values.first?.pages.reachedHistoryLimit == true)

        await store.loadOlderAgentFeed()

        #expect(await router.recordedWorkstreamFeedListCursors().count == 7)
    }
}
