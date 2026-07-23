import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellCompositeHideMacTests {
    @Test func hidingLastVisibleMacClearsSavedMacHint() async throws {
        let defaultsSuiteName = "hide-last-mac-hint-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(true, forKey: "cmux.mobile.hasKnownPairedMac")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: true
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults
        )
        await store.loadPairedMacs()
        #expect(store.hasKnownPairedMac)

        await store.hideMac(macDeviceID: "mac-a")

        #expect(store.pairedMacs.isEmpty)
        #expect(store.displayPairedMacs.isEmpty)
        #expect(!store.hasKnownPairedMac)
    }

    @Test func hideStoredMacFiltersOnlyExactAliasAndUnhideRestoresCustomization() async throws {
        let defaultsSuiteName = "hide-exact-alias-hint-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(true, forKey: "cmux.mobile.hasKnownPairedMac")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-old",
                        displayName: "Lawrence Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false,
                        customName: "Older build",
                        customColor: "palette:3",
                        customIcon: "laptopcomputer"
                    ),
                    try Self.pairedMac(
                        id: "mac-fresh",
                        displayName: "Lawrence Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: true
                    ),
                    try Self.pairedMac(
                        id: "mac-other",
                        displayName: "Other Mac",
                        host: "100.82.214.113",
                        lastSeenAt: Date(timeIntervalSince1970: 30),
                        isActive: false
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults
        )
        await store.loadPairedMacs()

        await store.hideStoredMac(macDeviceID: "mac-old")

        #expect(try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a").map(\.macDeviceID) == ["mac-old", "mac-fresh", "mac-other"])
        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-fresh", "mac-other"])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-fresh", "mac-other"])
        let hidden = try #require(store.hiddenComputers.first)
        #expect(hidden.macDeviceID == "mac-old")
        #expect(hidden.customColor == "palette:3")
        #expect(hidden.customIcon == "laptopcomputer")
        #expect(store.hasKnownPairedMac)

        await store.unhideMacDeviceID("mac-old")

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-old", "mac-fresh", "mac-other"])
        let restored = try #require(store.pairedMacs.first { $0.macDeviceID == "mac-old" })
        #expect(restored.customName == "Older build")
        #expect(restored.customColor == "palette:3")
        #expect(restored.customIcon == "laptopcomputer")
    }

    @Test func hideKeepsSQLiteRowAndCreatesNoPendingDeleteOrTombstone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let inner = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let backup = FakeBackup()
        let pendingDeletes = InMemoryPairedMacPendingDeleteStore()
        let pairedStore = BackingUpPairedMacStore(
            inner: inner,
            backup: backup,
            teamIDProvider: { "team-a" },
            pendingDeleteStore: pendingDeletes
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.82.214.112", port: 50922)
            )],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 10)
        )
        let uploadCountBeforeHide = await backup.uploadedOps().count
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()

        await store.hideMac(macDeviceID: "mac-a")

        #expect(try await inner.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        ).map(\.macDeviceID) == ["mac-a"])
        #expect(await pendingDeletes.load(scope: "user-1\u{0}team-a").isEmpty)
        let hideOps = Array((await backup.uploadedOps()).dropFirst(uploadCountBeforeHide))
        #expect(hideOps.isEmpty)
        #expect(store.pairedMacs.isEmpty)
        #expect(store.hiddenComputers.map(\.macDeviceID) == ["mac-a"])
    }

    @Test func hidingMacClearsAnonymousWorkspaceSnapshotOwnedByThatMac() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Lawrence Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        store.setWorkspaceStatesForTesting([
            MobileShellComposite.foregroundAnonymousKey: MacWorkspaceState(
                macDeviceID: MobileShellComposite.foregroundAnonymousKey,
                workspaces: [
                    MobileWorkspacePreview(
                        id: "stale-workspace",
                        macDeviceID: "mac-a",
                        name: "Stale",
                        terminals: []
                    ),
                ],
                status: .unavailable
            ),
        ], foregroundMacDeviceID: nil)
        #expect(store.workspaces.map(\.rpcWorkspaceID.rawValue) == ["stale-workspace"])

        await store.hideMac(macDeviceID: "mac-a")

        #expect(store.pairedMacs.isEmpty)
        #expect(store.displayPairedMacs.isEmpty)
        #expect(store.workspaces.isEmpty)
    }

    @Test func hidingActiveMacPreservesRemainingMacWorkspaceSnapshot() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: true
                    ),
                    try Self.pairedMac(
                        id: "mac-b",
                        displayName: "Laptop Mac",
                        host: "100.82.214.113",
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: false
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        #expect(store.applyNotificationFeedSnapshot(
            try Self.notificationResponse(revision: 7, id: "active-mac-notification"),
            macDeviceID: "mac-a",
            displayName: "Desk Mac"
        ))
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "deleted-workspace",
                        macDeviceID: "mac-a",
                        name: "Deleted",
                        terminals: []
                    ),
                ],
                status: .connected
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "remaining-workspace",
                        macDeviceID: "mac-b",
                        name: "Remaining",
                        terminals: []
                    ),
                ],
                status: .connected
            ),
        ], foregroundMacDeviceID: "mac-a")
        #expect(store.workspaces.map(\.rpcWorkspaceID.rawValue) == ["deleted-workspace", "remaining-workspace"])

        await store.hideMac(macDeviceID: "mac-a")

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(store.workspaces.map(\.rpcWorkspaceID.rawValue) == ["remaining-workspace"])
        #expect(store.connectionState == .disconnected)
        #expect(store.macConnectionStatus == .unavailable)
        #expect(store.workspaceListConnectionStatus == .connected)
        #expect(store.workspaceListConnectedRefreshTargetMacDeviceID() == "mac-b")
        #expect(store.notificationFeedSnapshotsByMac["mac-a"] == nil)
        #expect(store.notificationFeedItems.isEmpty)
    }

    @Test func staleForegroundSnapshotDoesNotHideUnavailableWorkspaceList() async throws {
        let store = MobileShellComposite(connectionState: .disconnected)
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "foreground-workspace",
                        macDeviceID: "mac-a",
                        name: "Foreground",
                        terminals: []
                    ),
                ],
                status: .connected
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "secondary-workspace",
                        macDeviceID: "mac-b",
                        name: "Secondary",
                        terminals: []
                    ),
                ],
                status: .unavailable
            ),
        ], foregroundMacDeviceID: "mac-a")

        #expect(store.macConnectionStatus == .unavailable)
        #expect(store.workspaceListConnectionStatus == .unavailable)
    }

    @Test func hidingKnownMacInvalidatesStoredMacReconnectAttempt() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: true
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        let generationBeforeHide = store.storedMacReconnectGeneration

        await store.hideMac(macDeviceID: "mac-a")

        #expect(store.storedMacReconnectGeneration > generationBeforeHide)
    }

    @Test func hidingMacFiltersOnlyMatchingRowsFromMixedWorkspaceBucket() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false
                    ),
                    try Self.pairedMac(
                        id: "mac-b",
                        displayName: "Laptop Mac",
                        host: "100.82.214.113",
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: true
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        store.setWorkspaceStatesForTesting([
            MobileShellComposite.foregroundAnonymousKey: MacWorkspaceState(
                macDeviceID: MobileShellComposite.foregroundAnonymousKey,
                workspaces: [
                    MobileWorkspacePreview(
                        id: "deleted-workspace",
                        macDeviceID: "mac-a",
                        name: "Deleted",
                        terminals: []
                    ),
                    MobileWorkspacePreview(
                        id: "remaining-workspace",
                        macDeviceID: "mac-b",
                        name: "Remaining",
                        terminals: []
                    ),
                ],
                status: .connected
            ),
        ], foregroundMacDeviceID: nil)

        await store.hideMac(macDeviceID: "mac-a")

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(store.workspaces.map(\.rpcWorkspaceID.rawValue) == ["remaining-workspace"])
        #expect(store.workspaceListConnectionStatus == .connected)
    }

    @Test func hideNeverCallsFailingRemoveAndStillPrunesDerivedState() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false
                    ),
                    try Self.pairedMac(
                        id: "mac-b",
                        displayName: "Laptop Mac",
                        host: "100.82.214.113",
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: true
                    ),
                ],
            ],
            blockedTeams: []
        )
        await pairedStore.failRemove(macDeviceID: "mac-a")
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        #expect(store.applyNotificationFeedSnapshot(
            try Self.notificationResponse(revision: 5, id: "mac-a-notification"),
            macDeviceID: "mac-a",
            displayName: "Desk Mac"
        ))
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "mac-a-workspace",
                        macDeviceID: "mac-a",
                        name: "Desk",
                        terminals: []
                    ),
                ],
                status: .connected
            ),
        ], foregroundMacDeviceID: nil)

        await store.hideMac(macDeviceID: "mac-a")
        await store.loadPairedMacs()

        #expect(try await pairedStore.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        ).map(\.macDeviceID) == ["mac-a", "mac-b"])
        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(store.workspaces.isEmpty)
        #expect(store.notificationFeedSnapshotsByMac["mac-a"] == nil)
        #expect(store.notificationFeedKnownRevisionsByMac["mac-a"] == nil)
        #expect(!store.notificationFeedSuccessfulMacIDs.contains("mac-a"))
        #expect(store.notificationFeedItems.isEmpty)
        #expect(store.hiddenComputers.map(\.macDeviceID) == ["mac-a"])
    }

    @Test func hideRemovesNotificationFeedSnapshot() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        #expect(store.applyNotificationFeedSnapshot(
            try Self.notificationResponse(revision: 5, id: "mac-a-notification"),
            macDeviceID: "mac-a",
            displayName: "Desk Mac"
        ))

        await store.hideMac(macDeviceID: "mac-a")

        #expect(store.notificationFeedSnapshotsByMac["mac-a"] == nil)
        #expect(store.notificationFeedKnownRevisionsByMac["mac-a"] == nil)
        #expect(!store.notificationFeedSuccessfulMacIDs.contains("mac-a"))
        #expect(store.notificationFeedItems.isEmpty)
    }

    private static func pairedMac(
        id: String,
        displayName: String,
        host: String,
        port: Int = 50922,
        lastSeenAt: Date,
        isActive: Bool,
        customName: String? = nil,
        customColor: String? = nil,
        customIcon: String? = nil,
        routes: [CmxAttachRoute]? = nil,
        teamID: String? = "team-a"
    ) throws -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: displayName,
            routes: routes ?? [try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: lastSeenAt,
            isActive: isActive,
            stackUserID: "user-1",
            teamID: teamID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon
        )
    }

    private static func notificationResponse(
        revision: Int,
        id: String
    ) throws -> MobileNotificationFeedListResponse {
        try MobileNotificationFeedListResponse.decode(Data(
            #"{"revision":\#(revision),"notifications":[{"id":"\#(id)","workspace_id":"workspace","title":"Title","body":"Body","created_at":100,"is_read":false}]}"#.utf8
        ))
    }
}
