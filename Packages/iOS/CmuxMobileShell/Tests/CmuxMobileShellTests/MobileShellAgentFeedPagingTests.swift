@testable import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing

@MainActor
@Suite("Mobile shell agent feed paging")
struct MobileShellAgentFeedPagingTests {
    @Test("Exact navigation fails closed when the captured surface is stale")
    func exactNavigationRejectsMissingSurface() async {
        var workspace = MobileWorkspacePreview(
            id: "workspace-row",
            macDeviceID: "mac",
            name: "Workspace",
            terminals: [MobileTerminalPreview(id: "other-surface", name: "Other")]
        )
        workspace.remoteWorkspaceID = "workspace-remote"
        let store = MobileShellComposite(connectionState: .connected, workspaces: [workspace])
        store.foregroundMacDeviceID = "mac"

        let opened = await store.openAgentFeedItem(feedItem(surfaceID: "stale-surface"))

        #expect(!opened)
        #expect(store.deeplinkWorkspaceNavigationRequest == nil)
        #expect(store.selectedWorkspaceID == "workspace-row")
        #expect(store.selectedTerminalID == "other-surface")
    }

    @Test("Exact navigation selects the captured workspace and surface")
    func exactNavigationSelectsSurface() async {
        var workspace = MobileWorkspacePreview(
            id: "workspace-row",
            macDeviceID: "mac",
            name: "Workspace",
            terminals: [MobileTerminalPreview(id: "surface", name: "Agent")]
        )
        workspace.remoteWorkspaceID = "workspace-remote"
        let store = MobileShellComposite(connectionState: .connected, workspaces: [workspace])
        store.foregroundMacDeviceID = "mac"

        let opened = await store.openAgentFeedItem(feedItem(surfaceID: "surface"))

        #expect(opened)
        #expect(store.selectedWorkspaceID == "workspace-row")
        #expect(store.selectedTerminalID == "surface")
        #expect(store.deeplinkWorkspaceNavigationRequest?.origin == .notificationFeed)
    }

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

    private func feedItem(surfaceID: String) -> MobileAgentFeedItem {
        MobileAgentFeedItem(
            macDeviceID: "mac",
            macInstanceTag: nil,
            macDisplayName: "Mac",
            connectionStatus: .connected,
            wire: MobileWorkstreamFeedListItem(
                id: UUID(),
                workstreamID: "agent",
                source: "codex",
                kind: "assistantMessage",
                createdAt: Date(),
                updatedAt: Date(),
                title: "Agent update",
                workspaceID: "workspace-remote",
                surfaceID: surfaceID,
                status: .telemetry,
                payload: .message(text: "Done", fromUser: false)
            )
        )
    }
}
