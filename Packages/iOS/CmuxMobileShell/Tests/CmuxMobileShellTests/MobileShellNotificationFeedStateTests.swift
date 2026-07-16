@testable import CmuxMobileShell
import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing

@MainActor
@Suite("Mobile shell notification feed state")
struct MobileShellNotificationFeedStateTests {
    @Test("Newer per-Mac revisions win and all Macs aggregate chronologically")
    func revisionAndAggregation() throws {
        let store = MobileShellComposite()

        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 2, id: "a-old", createdAt: 100),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 7, id: "b-new", createdAt: 200),
            macDeviceID: "mac-b",
            displayName: "Laptop"
        ))
        #expect(store.notificationFeedItems.map(\.notificationID) == ["b-new", "a-old"])

        store.notificationFeedKnownRevisionsByMac["mac-a"] = 4
        #expect(!store.applyNotificationFeedSnapshot(
            try response(revision: 3, id: "a-stale", createdAt: 300),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(store.notificationFeedRefreshPendingMacIDs.contains("mac-a"))
        #expect(store.notificationFeedItems.map(\.notificationID) == ["b-new", "a-old"])

        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 4, id: "a-current", createdAt: 300),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(store.notificationFeedItems.map(\.notificationID) == ["a-current", "b-new"])
    }

    @Test("Reset drops account-scoped notification content")
    func resetDropsContent() throws {
        let store = MobileShellComposite()
        _ = store.applyNotificationFeedSnapshot(
            try response(revision: 1, id: "private", createdAt: 100),
            macDeviceID: "mac",
            displayName: "Mac"
        )

        store.resetNotificationFeed()

        #expect(store.notificationFeedItems.isEmpty)
        #expect(store.notificationFeedSnapshotsByMac.isEmpty)
        #expect(store.notificationFeedStatus == .idle)
    }

    @Test("Read mutations preserve the last complete snapshot revision")
    func readMutationPreservesSnapshotRevision() throws {
        let store = MobileShellComposite()
        _ = store.applyNotificationFeedSnapshot(
            try response(revision: 2, id: "notification", createdAt: 100),
            macDeviceID: "mac",
            displayName: "Mac"
        )

        store.applyNotificationFeedReadMutation(
            macDeviceID: "mac",
            notificationIDs: ["notification"],
            revision: 5
        )

        #expect(store.notificationFeedSnapshotsByMac["mac"]?.revision == 2)
        #expect(store.notificationFeedKnownRevisionsByMac["mac"] == 5)
        #expect(store.notificationFeedItems.first?.isRead == true)
    }

    @Test("Active ticket preserves the foreground feed before foreground identity settles")
    func activeTicketFallbackPreservesForegroundFeed() throws {
        let store = MobileShellComposite()
        store.activeTicket = try CmxAttachTicket(
            workspaceID: "workspace",
            terminalID: "surface",
            macDeviceID: "ticket-mac",
            macDisplayName: "Studio",
            routes: [
                try CmxAttachRoute(
                    id: "local",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "127.0.0.1", port: 5000),
                    priority: 100
                ),
            ],
            expiresAt: Date().addingTimeInterval(60)
        )
        _ = store.applyNotificationFeedSnapshot(
            try response(revision: 1, id: "foreground", createdAt: 200),
            macDeviceID: "ticket-mac",
            displayName: "Studio"
        )
        _ = store.applyNotificationFeedSnapshot(
            try response(revision: 1, id: "other", createdAt: 100),
            macDeviceID: "other-mac",
            displayName: "Other"
        )

        store.retainForegroundNotificationFeedSnapshot()

        #expect(Set(store.notificationFeedSnapshotsByMac.keys) == ["ticket-mac"])
        #expect(store.notificationFeedItems.map(\.notificationID) == ["foreground"])
    }

    @Test("Open reuses deeplink navigation and selects the target surface")
    func openNavigatesToSurface() async {
        let workspace = MobileWorkspacePreview(
            id: "workspace-row",
            macDeviceID: "mac",
            name: "cmux",
            terminals: [MobileTerminalPreview(id: "surface", name: "agent")]
        )
        var remoteWorkspace = workspace
        remoteWorkspace.remoteWorkspaceID = "workspace-remote"
        let store = MobileShellComposite(
            connectionState: .connected,
            workspaces: [remoteWorkspace]
        )
        store.foregroundMacDeviceID = "mac"
        let item = MobileNotificationFeedItem(
            macDeviceID: "mac",
            notificationID: "notification",
            macDisplayName: "Mac",
            remoteWorkspaceID: "workspace-remote",
            remoteSurfaceID: "surface",
            title: "Approval needed",
            body: "Allow the command?",
            createdAt: Date(),
            isRead: false,
            connectionStatus: .connected
        )

        await store.openNotificationFeedItem(item)

        #expect(store.selectedWorkspaceID == "workspace-row")
        #expect(store.selectedTerminalID == "surface")
        #expect(store.deeplinkWorkspaceNavigationRequest?.origin == .notificationFeed)
        #expect(store.consumeDeeplinkWorkspaceNavigationRequest() == "workspace-row")
    }

    private func response(
        revision: Int,
        id: String,
        createdAt: Double
    ) throws -> MobileNotificationFeedListResponse {
        try MobileNotificationFeedListResponse.decode(Data(
            #"{"revision":\#(revision),"notifications":[{"id":"\#(id)","workspace_id":"workspace","title":"Title","body":"Body","created_at":\#(createdAt),"is_read":false}]}"#.utf8
        ))
    }
}
