@testable import CmuxMobileShell
import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing

@MainActor
@Suite("Mobile shell notification feed state")
struct MobileShellNotificationFeedStateTests {
    @Test("Sibling pairings keep separate snapshots under tagged owner keys")
    func taggedOwnerKeysStaySeparate() throws {
        let store = MobileShellComposite()
        let nightlyKey = "mac-a\u{1F}nightly"
        let stableKey = "mac-a\u{1F}default"

        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 3, id: "shared-id", createdAt: 100),
            macDeviceID: nightlyKey,
            displayName: "Desk Mac"
        ))
        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 5, id: "shared-id", createdAt: 200),
            macDeviceID: stableKey,
            displayName: "Desk Mac"
        ))

        // Equal Mac-local ids from sibling builds must not dedupe, and each
        // owner key tracks its own revision.
        #expect(store.notificationFeedItems.count == 2)
        #expect(store.notificationFeedSnapshotsByMac[nightlyKey]?.revision == 3)
        #expect(store.notificationFeedSnapshotsByMac[stableKey]?.revision == 5)
        #expect(Set(store.notificationFeedItems.map(\.macDeviceID)) == ["mac-a"])
    }

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

    @Test("Aggregation caps the retained phone feed at newest rows")
    func aggregationCapsRetainedFeedAtNewestRows() throws {
        let store = MobileShellComposite()
        let cap = MobileNotificationFeedAggregation.maxItemCount
        let olderEntries = (0..<25).map { offset in
            NotificationResponseEntry(
                id: "old-\(offset)",
                createdAt: Double(offset),
                isRead: false
            )
        }
        let newerEntries = (0..<cap).map { offset in
            NotificationResponseEntry(
                id: "new-\(offset)",
                createdAt: 10_000 + Double(offset),
                isRead: false
            )
        }

        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 1, entries: olderEntries),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 1, entries: newerEntries),
            macDeviceID: "mac-b",
            displayName: "Laptop"
        ))

        #expect(store.notificationFeedItems.count == cap)
        #expect(store.notificationFeedUnreadCount == cap)
        #expect(store.notificationFeedItems.allSatisfy { $0.macDeviceID == "mac-b" })
        #expect(store.notificationFeedItems.first?.notificationID == "new-\(cap - 1)")
    }

    @Test("Computer-scoped feeds aggregate before the global feed cap")
    func computerScopedFeedsAggregateBeforeGlobalCap() throws {
        var macAWorkspace = MobileWorkspacePreview(
            id: "mac-a-workspace-row",
            macDeviceID: "mac-a",
            name: "A",
            terminals: []
        )
        macAWorkspace.remoteWorkspaceID = "workspace"
        var macBWorkspace = MobileWorkspacePreview(
            id: "mac-b-workspace-row",
            macDeviceID: "mac-b",
            name: "B",
            terminals: []
        )
        macBWorkspace.remoteWorkspaceID = "workspace"
        let store = MobileShellComposite(workspaces: [macAWorkspace, macBWorkspace])
        let cap = MobileNotificationFeedAggregation.maxItemCount
        let macAEntries = (0..<cap).map { offset in
            NotificationResponseEntry(
                id: "a-\(offset)",
                createdAt: 10_000 + Double(offset),
                isRead: false
            )
        }
        let macBEntries = (0..<10).map { offset in
            NotificationResponseEntry(
                id: "b-\(offset)",
                createdAt: Double(offset),
                isRead: false
            )
        }

        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 1, entries: macAEntries),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 1, entries: macBEntries),
            macDeviceID: "mac-b",
            displayName: "Laptop"
        ))

        #expect(store.notificationFeedItems.count == cap)
        #expect(store.notificationFeedItems.allSatisfy { $0.macDeviceID == "mac-a" })

        let scopedItems = store.notificationFeedItems(scopedTo: ["mac-b"])
        #expect(scopedItems.map(\.notificationID) == (0..<10).reversed().map { "b-\($0)" })
        #expect(scopedItems.allSatisfy { $0.macDeviceID == "mac-b" })
    }

    @Test("Visible feed omits notifications whose workspace no longer exists")
    func visibleFeedOmitsDeletedWorkspaceNotifications() throws {
        var liveWorkspace = MobileWorkspacePreview(
            id: "live-workspace-row",
            macDeviceID: "mac",
            name: "Live workspace",
            terminals: []
        )
        liveWorkspace.remoteWorkspaceID = "live-workspace"
        let store = MobileShellComposite(workspaces: [liveWorkspace])
        let response = try MobileNotificationFeedListResponse.decode(Data(
            """
            {"revision":1,"notifications":[
            {"id":"deleted","workspace_id":"deleted-workspace","title":"Deleted","body":"Orphaned","created_at":200,"is_read":false},
            {"id":"live","workspace_id":"live-workspace","title":"Live","body":"Reachable","created_at":100,"is_read":false}
            ]}
            """.utf8
        ))

        #expect(store.applyNotificationFeedSnapshot(
            response,
            macDeviceID: "mac",
            displayName: "Mac"
        ))
        #expect(store.notificationFeedItems.map(\.notificationID) == ["deleted", "live"])

        let visibleItems = store.notificationFeedItems(scopedTo: nil)

        #expect(visibleItems.map(\.notificationID) == ["live"])
    }

    @Test("Visible feed fails closed when one pairing exposes duplicate target rows")
    func visibleFeedOmitsAmbiguousDuplicateWorkspaceTargets() throws {
        var firstWorkspace = MobileWorkspacePreview(
            id: "first-row",
            macDeviceID: "mac",
            name: "First",
            terminals: []
        )
        firstWorkspace.macInstanceTag = "norph"
        firstWorkspace.remoteWorkspaceID = "workspace"
        var secondWorkspace = MobileWorkspacePreview(
            id: "second-row",
            macDeviceID: "mac",
            name: "Second",
            terminals: []
        )
        secondWorkspace.macInstanceTag = "norph"
        secondWorkspace.remoteWorkspaceID = "workspace"
        let store = MobileShellComposite(workspaces: [firstWorkspace, secondWorkspace])

        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 1, id: "ambiguous", createdAt: 100),
            macDeviceID: "mac\u{1F}norph",
            displayName: "Mac"
        ))

        #expect(store.notificationFeedItems.map(\.notificationID) == ["ambiguous"])
        #expect(store.notificationFeedItems(scopedTo: nil).isEmpty)
    }

    @Test("Device-only notifications cannot borrow a tagged workspace")
    func legacyNotificationDoesNotRouteToTaggedWorkspace() throws {
        var nightlyWorkspace = MobileWorkspacePreview(
            id: "nightly-row",
            macDeviceID: "mac",
            name: "Nightly",
            terminals: []
        )
        nightlyWorkspace.macInstanceTag = "nightly"
        nightlyWorkspace.remoteWorkspaceID = "workspace"
        let store = MobileShellComposite(workspaces: [nightlyWorkspace])

        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 1, id: "legacy", createdAt: 100),
            macDeviceID: "mac",
            displayName: "Mac"
        ))

        #expect(store.notificationFeedItems.map(\.notificationID) == ["legacy"])
        #expect(store.notificationFeedItems(scopedTo: nil).isEmpty)
    }

    @Test("Mark All targets all selected Macs before applying the visible feed cap")
    func markAllTargetsSelectedMacsBeforeVisibleFeedCap() async throws {
        let store = MobileShellComposite()
        let cap = MobileNotificationFeedAggregation.maxItemCount
        let macAEntries = (0..<cap).map { offset in
            NotificationResponseEntry(
                id: "a-\(offset)",
                createdAt: 10_000 + Double(offset),
                isRead: false
            )
        }
        let macBEntries = (0..<3).map { offset in
            NotificationResponseEntry(
                id: "b-\(offset)",
                createdAt: Double(offset),
                isRead: false
            )
        }

        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 1, entries: macAEntries),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 1, entries: macBEntries),
            macDeviceID: "mac-b",
            displayName: "Laptop"
        ))
        #expect(store.notificationFeedItems.count == cap)
        #expect(store.notificationFeedItems.allSatisfy { $0.macDeviceID == "mac-a" })

        let macARouter = RoutingHostRouter()
        let macBRouter = RoutingHostRouter()
        try installSecondaryClient(
            on: store,
            macDeviceID: "mac-a",
            router: macARouter,
            supportedHostCapabilities: [MobileShellComposite.notificationFeedCapability]
        )
        try installSecondaryClient(
            on: store,
            macDeviceID: "mac-b",
            router: macBRouter,
            supportedHostCapabilities: [MobileShellComposite.notificationFeedCapability]
        )

        await store.markNotificationFeedItemsRead(scopedTo: nil)

        #expect(await macARouter.recordedNotificationFeedMarkAllReadCount() == 1)
        #expect(await macBRouter.recordedNotificationFeedMarkAllReadCount() == 1)
    }

    @Test("Source cache preserves per-Mac tails so aggregation refills after another source disappears")
    func sourceCachePreservesPerMacTailsForAggregateRefill() throws {
        let store = MobileShellComposite()
        let cap = MobileNotificationFeedAggregation.maxItemCount
        let newerCount = 25
        let olderEntries = (0..<cap).map { offset in
            NotificationResponseEntry(
                id: "old-\(offset)",
                createdAt: Double(offset),
                isRead: false
            )
        }
        let newerEntries = (0..<newerCount).map { offset in
            NotificationResponseEntry(
                id: "new-\(offset)",
                createdAt: 10_000 + Double(offset),
                isRead: false
            )
        }

        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 1, entries: olderEntries),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 1, entries: newerEntries),
            macDeviceID: "mac-b",
            displayName: "Laptop"
        ))

        let sourceItemCount = store.notificationFeedSnapshotsByMac.values.reduce(0) { count, snapshot in
            count + snapshot.items.count
        }
        #expect(sourceItemCount == cap + newerCount)
        #expect(store.notificationFeedSnapshotsByMac["mac-b"]?.items.count == newerCount)
        #expect(store.notificationFeedSnapshotsByMac["mac-a"]?.items.count == cap)
        #expect(store.notificationFeedSnapshotsByMac["mac-a"]?.items.contains {
            $0.notificationID == "old-0"
        } == true)
        #expect(store.notificationFeedItems.count == cap)

        store.removeNotificationFeedSnapshot(macDeviceID: "mac-b")

        #expect(store.notificationFeedItems.count == cap)
        #expect(store.notificationFeedItems.allSatisfy { $0.macDeviceID == "mac-a" })
        #expect(store.notificationFeedItems.contains { $0.notificationID == "old-0" })
    }

    @Test("Source cache deduplicates repeated wire notification identities")
    func sourceCacheDeduplicatesRepeatedWireNotificationIdentities() throws {
        let store = MobileShellComposite()
        let cap = MobileNotificationFeedAggregation.maxItemCount
        let duplicatedEntries = (0..<cap).map { offset in
            NotificationResponseEntry(
                id: "duplicate",
                createdAt: Double(offset),
                isRead: false
            )
        }

        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 1, entries: duplicatedEntries),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(store.applyNotificationFeedSnapshot(
            try response(revision: 1, entries: duplicatedEntries),
            macDeviceID: "mac-b",
            displayName: "Laptop"
        ))

        let sourceItemCount = store.notificationFeedSnapshotsByMac.values.reduce(0) { count, snapshot in
            count + snapshot.items.count
        }
        #expect(sourceItemCount == 2)
        #expect(store.notificationFeedSnapshotsByMac["mac-a"]?.items.count == 1)
        #expect(store.notificationFeedSnapshotsByMac["mac-b"]?.items.count == 1)
        #expect(store.notificationFeedItems.count == 2)
    }

    @Test("Legacy Mac payloads are bounded before phone retention")
    func legacyMacPayloadsAreBoundedBeforeRetention() throws {
        let store = MobileShellComposite()
        let oversizedText = String(repeating: "x", count: 4_096)
        let oversizedIdentifier = String(repeating: "i", count: 513)
        let response = try MobileNotificationFeedListResponse.decode(Data(
            """
            {"revision":1,"notifications":[
            {"id":"valid","workspace_id":"workspace","surface_id":"\(oversizedText)",
            "title":"\(oversizedText)","subtitle":"\(oversizedText)",
            "body":"\(oversizedText)","created_at":200,"is_read":false,
            "workspace_title":"\(oversizedText)","surface_title":"\(oversizedText)"},
            {"id":"\(oversizedIdentifier)","workspace_id":"workspace",
            "title":"Dropped","body":"Dropped","created_at":300,"is_read":false}
            ]}
            """.utf8
        ))

        #expect(store.applyNotificationFeedSnapshot(
            response,
            macDeviceID: "mac",
            displayName: oversizedText
        ))

        let item = try #require(store.notificationFeedItems.first)
        #expect(store.notificationFeedItems.count == 1)
        #expect(item.notificationID == "valid")
        #expect(item.remoteSurfaceID == nil)
        #expect(item.macDisplayName.utf8.count == 512)
        #expect(item.title.utf8.count == 512)
        #expect(item.subtitle?.utf8.count == 512)
        #expect(item.body.utf8.count == 2_048)
        #expect(item.workspaceTitle?.utf8.count == 512)
        #expect(item.surfaceTitle?.utf8.count == 512)
        #expect(store.notificationFeedSnapshotsByMac["mac"]?.items.first?.body.utf8.count == 2_048)
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

    private func response(
        revision: Int,
        entries: [NotificationResponseEntry]
    ) throws -> MobileNotificationFeedListResponse {
        let notifications = entries.map { entry in
            #"{"id":"\#(entry.id)","workspace_id":"workspace","title":"Title","body":"Body","created_at":\#(entry.createdAt),"is_read":\#(entry.isRead)}"#
        }.joined(separator: ",")
        return try MobileNotificationFeedListResponse.decode(Data(
            #"{"revision":\#(revision),"notifications":[\#(notifications)]}"#.utf8
        ))
    }

}
