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
        #expect(store.notificationFeedUnreadCount == 2)

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
        #expect(store.notificationFeedUnreadCount == 1)

        store.resetNotificationFeed()

        #expect(store.notificationFeedItems.isEmpty)
        #expect(store.notificationFeedUnreadCount == 0)
        #expect(store.notificationFeedSnapshotsByMac.isEmpty)
        #expect(store.notificationFeedStatus == .idle)
    }

    @Test("Read-state mutations preserve the last complete snapshot revision")
    func readStateMutationPreservesSnapshotRevision() throws {
        let store = MobileShellComposite()
        _ = store.applyNotificationFeedSnapshot(
            try response(revision: 2, id: "notification", createdAt: 100),
            macDeviceID: "mac",
            displayName: "Mac"
        )
        #expect(store.notificationFeedUnreadCount == 1)

        store.applyNotificationFeedReadStateMutation(
            macDeviceID: "mac",
            notificationIDs: ["notification"],
            isRead: true,
            revision: 5
        )

        #expect(store.notificationFeedSnapshotsByMac["mac"]?.revision == 2)
        #expect(store.notificationFeedKnownRevisionsByMac["mac"] == 5)
        #expect(store.notificationFeedItems.first?.isRead == true)
        #expect(store.notificationFeedUnreadCount == 0)

        store.applyNotificationFeedReadStateMutation(
            macDeviceID: "mac",
            notificationIDs: ["notification"],
            isRead: false,
            revision: 6
        )

        #expect(store.notificationFeedSnapshotsByMac["mac"]?.revision == 2)
        #expect(store.notificationFeedKnownRevisionsByMac["mac"] == 6)
        #expect(store.notificationFeedItems.first?.isRead == false)
        #expect(store.notificationFeedUnreadCount == 1)
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

    @Test("Open follows a retargetable surface to its current workspace")
    func openFollowsRetargetedSurfaceOwner() async {
        var capturedWorkspace = MobileWorkspacePreview(
            id: "workspace-captured-row",
            macDeviceID: "mac",
            name: "Captured",
            terminals: [MobileTerminalPreview(id: "surface-other", name: "other")]
        )
        capturedWorkspace.remoteWorkspaceID = "workspace-captured"
        var liveWorkspace = MobileWorkspacePreview(
            id: "workspace-live-row",
            macDeviceID: "mac",
            name: "Live",
            terminals: [MobileTerminalPreview(id: "surface-retargeted", name: "agent")]
        )
        liveWorkspace.remoteWorkspaceID = "workspace-live"
        let store = MobileShellComposite(
            connectionState: .connected,
            workspaces: [capturedWorkspace, liveWorkspace]
        )
        store.foregroundMacDeviceID = "mac"
        let item = MobileNotificationFeedItem(
            macDeviceID: "mac",
            notificationID: "notification",
            macDisplayName: "Mac",
            remoteWorkspaceID: "workspace-captured",
            remoteSurfaceID: "surface-retargeted",
            title: "Approval needed",
            body: "Allow the command?",
            createdAt: Date(),
            isRead: true,
            connectionStatus: .connected
        )

        await store.openNotificationFeedItem(item)

        #expect(store.selectedWorkspaceID == "workspace-live-row")
        #expect(store.selectedTerminalID == "surface-retargeted")
        #expect(store.deeplinkWorkspaceNavigationRequest?.origin == .notificationFeed)
        #expect(store.consumeDeeplinkWorkspaceNavigationRequest() == "workspace-live-row")
    }

    @Test("Open fails closed when a retargetable surface no longer exists")
    func openFailsClosedForMissingRetargetableSurface() async {
        var capturedWorkspace = MobileWorkspacePreview(
            id: "workspace-captured-row",
            macDeviceID: "mac",
            name: "Captured",
            terminals: [MobileTerminalPreview(id: "surface-other", name: "other")]
        )
        capturedWorkspace.remoteWorkspaceID = "workspace-captured"
        let store = MobileShellComposite(
            connectionState: .connected,
            workspaces: [capturedWorkspace]
        )
        store.foregroundMacDeviceID = "mac"
        let item = MobileNotificationFeedItem(
            macDeviceID: "mac",
            notificationID: "missing-surface",
            macDisplayName: "Mac",
            remoteWorkspaceID: "workspace-captured",
            remoteSurfaceID: "surface-missing",
            title: "Approval needed",
            body: "Allow the command?",
            createdAt: Date(),
            isRead: true,
            retargetsToLiveSurfaceOwner: true,
            connectionStatus: .connected
        )

        await store.openNotificationFeedItem(item)

        #expect(store.selectedWorkspaceID == "workspace-captured-row")
        #expect(store.selectedTerminalID == "surface-other")
        #expect(store.deeplinkWorkspaceNavigationRequest == nil)
        #expect(store.consumeDeeplinkWorkspaceNavigationRequest() == nil)
    }

    @Test("Cancelling a pending feed open prevents later navigation")
    func cancelPendingOpenPreventsNavigation() async {
        var workspace = MobileWorkspacePreview(
            id: "workspace-row",
            macDeviceID: "mac",
            name: "cmux",
            terminals: [MobileTerminalPreview(id: "surface", name: "agent")]
        )
        workspace.remoteWorkspaceID = "workspace-remote"
        let store = MobileShellComposite(
            connectionState: .connected,
            workspaces: [workspace]
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
            isRead: true,
            connectionStatus: .connected
        )

        store.requestOpenNotificationFeedItem(item)
        let cancelledTask = store.cancelPendingNotificationFeedOpen()
        await cancelledTask?.value

        #expect(store.selectedWorkspaceID == "workspace-row")
        #expect(store.selectedTerminalID == "surface")
        #expect(store.deeplinkWorkspaceNavigationRequest == nil)
        #expect(store.consumeDeeplinkWorkspaceNavigationRequest() == nil)
    }

    @Test("Open confines a source-scoped notification to its captured workspace")
    func openConfinesMovedSurface() async {
        var capturedWorkspace = MobileWorkspacePreview(
            id: "workspace-captured-row",
            macDeviceID: "mac",
            name: "Captured",
            terminals: [MobileTerminalPreview(id: "surface-captured", name: "captured")]
        )
        capturedWorkspace.remoteWorkspaceID = "workspace-captured"
        var liveWorkspace = MobileWorkspacePreview(
            id: "workspace-live-row",
            macDeviceID: "mac",
            name: "Live",
            terminals: [MobileTerminalPreview(id: "surface-moved", name: "moved")]
        )
        liveWorkspace.remoteWorkspaceID = "workspace-live"
        let store = MobileShellComposite(
            connectionState: .connected,
            workspaces: [capturedWorkspace, liveWorkspace]
        )
        store.foregroundMacDeviceID = "mac"
        let item = MobileNotificationFeedItem(
            macDeviceID: "mac",
            notificationID: "confined",
            macDisplayName: "Mac",
            remoteWorkspaceID: "workspace-captured",
            remoteSurfaceID: "surface-moved",
            title: "Confined",
            body: "Stay in the captured workspace",
            createdAt: Date(),
            isRead: true,
            retargetsToLiveSurfaceOwner: false,
            connectionStatus: .connected
        )

        await store.openNotificationFeedItem(item)

        #expect(store.selectedWorkspaceID == "workspace-captured-row")
        #expect(store.selectedTerminalID == "surface-captured")
        #expect(store.deeplinkWorkspaceNavigationRequest?.origin == .notificationFeed)
        #expect(store.consumeDeeplinkWorkspaceNavigationRequest() == "workspace-captured-row")
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
