import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellCompositePairedMacCoalescingTests {
    @Test func loadPairedMacsCoalescesDuplicateHostPortRows() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-old",
                        displayName: "Lawrence Mac",
                        host: " 100.82.214.112 ",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false,
                        customName: "Old custom",
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
            teamIDProvider: { "team-a" }
        )

        await store.loadPairedMacs()

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-old", "mac-fresh", "mac-other"])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-fresh", "mac-other"])
        #expect(Set(store.pairedMacAliasIDs(for: "mac-fresh")) == Set(["mac-old", "mac-fresh"]))
        #expect(store.displayPairedMacs.first?.customName == "Old custom")
        #expect(store.displayPairedMacs.first?.customColor == "palette:3")
        #expect(store.displayPairedMacs.first?.customIcon == "laptopcomputer")
        store.setWorkspaceStatesForTesting([
            "mac-old": MacWorkspaceState(
                macDeviceID: "mac-old",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "hidden-workspace",
                        macDeviceID: "mac-old",
                        name: "Hidden",
                        terminals: []
                    ),
                ],
                status: .connected
            ),
            "mac-fresh": MacWorkspaceState(
                macDeviceID: "mac-fresh",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "visible-workspace",
                        macDeviceID: "mac-fresh",
                        name: "Visible",
                        terminals: []
                    ),
                ],
                status: .connected
            ),
        ], foregroundMacDeviceID: "mac-old")
        let hiddenWorkspace = try #require(store.workspaces.first {
            $0.rpcWorkspaceID.rawValue == "hidden-workspace"
        })
        let visibleWorkspace = try #require(store.workspaces.first {
            $0.rpcWorkspaceID.rawValue == "visible-workspace"
        })
        #expect(hiddenWorkspace.machineCustomColor == "palette:3")
        #expect(hiddenWorkspace.machineCustomIcon == "laptopcomputer")
        #expect(visibleWorkspace.machineCustomColor == "palette:3")
        #expect(visibleWorkspace.machineCustomIcon == "laptopcomputer")

        await store.updateMacCustomization(macDeviceID: "mac-fresh", customName: "Desk setup", customColor: "palette:2", customIcon: "desktopcomputer")

        #expect(store.displayPairedMacs.first?.customName == "Desk setup")
        #expect(store.displayPairedMacs.first?.customColor == "palette:2")
        #expect(store.displayPairedMacs.first?.customIcon == "desktopcomputer")
        let customizedDuplicateRows = try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a")
            .filter { ["mac-old", "mac-fresh"].contains($0.macDeviceID) }
        #expect(customizedDuplicateRows.first { $0.macDeviceID == "mac-old" }?.customName == "Old custom")
        #expect(customizedDuplicateRows.first { $0.macDeviceID == "mac-fresh" }?.customName == "Desk setup")

        await store.forgetMac(macDeviceID: "mac-fresh")

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-other"])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-other"])
        #expect(store.workspaces.map(\.rpcWorkspaceID.rawValue).isEmpty)
        #expect(try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a").map(\.macDeviceID) == ["mac-other"])
    }

    @Test func presenceRoutesForHiddenDuplicateRefreshOnlyTheEmittingRow() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-old",
                        displayName: "Lawrence Mac",
                        host: "100.82.214.112",
                        port: 50922,
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false
                    ),
                    try Self.pairedMac(
                        id: "mac-fresh",
                        displayName: "Lawrence Mac",
                        host: "100.82.214.112",
                        port: 50922,
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: true
                    ),
                    try Self.pairedMac(
                        id: "mac-other",
                        displayName: "Other Mac",
                        host: "100.82.214.113",
                        port: 50922,
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
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()

        let freshRoute = try CmxAttachRoute(
            id: "fresh",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50922)
        )
        store.applyPresenceUpdate(
            .online(PresenceInstance(
                deviceId: "mac-old",
                tag: "default",
                platform: "mac",
                online: true,
                lastSeenAt: 1_000,
                routes: [freshRoute]
            )),
            scope: MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0)
        )
        await pairedStore.waitUntilUpsertCount(1)

        #expect(store.presenceSummary(for: "mac-fresh")?.online == true)
        let duplicateRows = try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a")
            .filter { ["mac-old", "mac-fresh"].contains($0.macDeviceID) }
        #expect(duplicateRows.count == 2)
        #expect(duplicateRows.first { $0.macDeviceID == "mac-old" }?.routes == [freshRoute])
        #expect(duplicateRows.first { $0.macDeviceID == "mac-fresh" }?.routes != [freshRoute])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-fresh", "mac-other"])
    }

    @Test func presenceRoutesDoNotFanOutWhenLogicalDuplicatesBothAdvertiseRoutes() async throws {
        let oldRoute = try CmxAttachRoute(
            id: "old",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50922)
        )
        let freshRoute = try CmxAttachRoute(
            id: "fresh",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50923)
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-old",
                        displayName: "Lawrence Mac",
                        host: "100.82.214.112",
                        port: 50922,
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false,
                        routes: [oldRoute]
                    ),
                    try Self.pairedMac(
                        id: "mac-fresh",
                        displayName: "Lawrence Mac",
                        host: "100.82.214.112",
                        port: 50922,
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: true,
                        routes: [freshRoute]
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

        store.applyPresenceUpdate(
            .snapshot(PresenceSnapshot(
                teamId: "team-a",
                now: 2_000,
                heartbeatIntervalMs: 15_000,
                offlineTimeoutMs: 45_000,
                devices: [
                    PresenceDevice(
                        deviceId: "mac-old",
                        platform: "mac",
                        online: true,
                        lastSeenAt: 1_000,
                        instances: [
                            PresenceInstance(
                                deviceId: "mac-old",
                                tag: "default",
                                platform: "mac",
                                online: true,
                                lastSeenAt: 1_000,
                                routes: [oldRoute]
                            ),
                        ]
                    ),
                    PresenceDevice(
                        deviceId: "mac-fresh",
                        platform: "mac",
                        online: true,
                        lastSeenAt: 2_000,
                        instances: [
                            PresenceInstance(
                                deviceId: "mac-fresh",
                                tag: "debug",
                                platform: "mac",
                                online: true,
                                lastSeenAt: 2_000,
                                routes: [freshRoute]
                            ),
                        ]
                    ),
                ]
            )),
            scope: MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0)
        )
        await store.waitForPushedRouteSyncForTesting()

        let duplicateRows = try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a")
            .filter { ["mac-old", "mac-fresh"].contains($0.macDeviceID) }
        #expect(await pairedStore.currentUpsertCount() == 0)
        #expect(duplicateRows.first { $0.macDeviceID == "mac-old" }?.routes == [oldRoute])
        #expect(duplicateRows.first { $0.macDeviceID == "mac-fresh" }?.routes == [freshRoute])
    }

    @Test func sameEndpointWithDifferentDisplayNamesStaysSeparate() async throws {
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
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 20),
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

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-a", "mac-b"])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-a", "mac-b"])
    }

    @Test func forgettingMacClearsAnonymousWorkspaceSnapshotOwnedByThatMac() async throws {
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

        await store.forgetMac(macDeviceID: "mac-a")

        #expect(store.pairedMacs.isEmpty)
        #expect(store.displayPairedMacs.isEmpty)
        #expect(store.workspaces.isEmpty)
    }

    @Test func forgettingActiveMacPreservesRemainingMacWorkspaceSnapshot() async throws {
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

        await store.forgetMac(macDeviceID: "mac-a")

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(store.workspaces.map(\.rpcWorkspaceID.rawValue) == ["remaining-workspace"])
        #expect(store.connectionState == .disconnected)
        #expect(store.macConnectionStatus == .unavailable)
        #expect(store.workspaceListConnectionStatus == .connected)
        #expect(store.workspaceListConnectedRefreshTargetMacDeviceID() == "mac-b")
    }

    @Test func forgettingMacFiltersOnlyMatchingRowsFromMixedWorkspaceBucket() async throws {
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

        await store.forgetMac(macDeviceID: "mac-a")

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(store.workspaces.map(\.rpcWorkspaceID.rawValue) == ["remaining-workspace"])
        #expect(store.workspaceListConnectionStatus == .connected)
    }

    @Test func failedForgetRestoresMacVisibilityAndForgottenTombstone() async throws {
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
            forgottenMacStore: InMemoryPairedMacForgottenStore()
        )
        await store.loadPairedMacs()
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

        await store.forgetMac(macDeviceID: "mac-a")
        await store.loadPairedMacs()

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-a", "mac-b"])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-a", "mac-b"])
        #expect(store.workspaces.map(\.rpcWorkspaceID.rawValue) == ["mac-a-workspace"])
    }

    @Test func forgettingMacSuppressesStaleStoreWriteFromSameSession() async throws {
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
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()

        await store.forgetMac(macDeviceID: "mac-a")
        try await pairedStore.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try CmxAttachRoute(
                id: "stale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.82.214.112", port: 50922)
            )],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 30)
        )

        await store.loadPairedMacs()

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(await store.secondaryAggregationCandidateMacIDsForTesting() == ["mac-b"])
    }

    @Test func forgettingMacSuppressesStaleStoreWriteAfterRelaunch() async throws {
        let suiteName = "forgotten-mac-relaunch-\(UUID().uuidString)"
        let forgottenStore = UserDefaultsPairedMacForgottenStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
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
        let firstStore = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            forgottenMacStore: forgottenStore
        )
        await firstStore.loadPairedMacs()

        await firstStore.forgetMac(macDeviceID: "mac-a")
        try await pairedStore.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try CmxAttachRoute(
                id: "stale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.82.214.112", port: 50922)
            )],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 30)
        )

        let relaunchedStore = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            forgottenMacStore: forgottenStore
        )

        await relaunchedStore.loadPairedMacs()

        #expect(relaunchedStore.pairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(relaunchedStore.displayPairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(await relaunchedStore.secondaryAggregationCandidateMacIDsForTesting() == ["mac-b"])
    }

    @Test func workspaceListReconnectPrefersSelectedUnavailableWorkspaceMac() async throws {
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
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "workspace-a",
                        macDeviceID: "mac-a",
                        name: "Desk",
                        terminals: []
                    ),
                ],
                status: .unavailable
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "workspace-b",
                        macDeviceID: "mac-b",
                        name: "Laptop",
                        terminals: []
                    ),
                ],
                status: .unavailable
            ),
        ], foregroundMacDeviceID: "mac-a")

        let workspaceB = try #require(store.workspaces.first {
            $0.rpcWorkspaceID.rawValue == "workspace-b"
        })
        store.selectedWorkspaceID = workspaceB.id

        #expect(store.workspaceListReconnectTargetMacDeviceID() == "mac-b")
    }

    @Test func workspaceListReconnectUsesSingleUnavailableWorkspaceOwner() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
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
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        store.setWorkspaceStatesForTesting([
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "workspace-b",
                        macDeviceID: "mac-b",
                        name: "Laptop",
                        terminals: []
                    ),
                ],
                status: .unavailable
            ),
        ], foregroundMacDeviceID: nil)

        store.selectedWorkspaceID = nil

        #expect(store.workspaceListReconnectTargetMacDeviceID() == "mac-b")
    }

    @Test func workspaceListReconnectDoesNotPickFirstUnavailableOwnerWithoutSelection() async throws {
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
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "workspace-a",
                        macDeviceID: "mac-a",
                        name: "Desk",
                        terminals: []
                    ),
                ],
                status: .unavailable
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "workspace-b",
                        macDeviceID: "mac-b",
                        name: "Laptop",
                        terminals: []
                    ),
                ],
                status: .unavailable
            ),
        ], foregroundMacDeviceID: nil)

        store.selectedWorkspaceID = nil

        #expect(store.workspaceListReconnectTargetMacDeviceID() == nil)
    }

    @Test func workspaceListConnectedRefreshDoesNotPickFirstConnectedOwnerWithoutSelection() async throws {
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
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "workspace-a",
                        macDeviceID: "mac-a",
                        name: "Desk",
                        terminals: []
                    ),
                ],
                status: .connected
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "workspace-b",
                        macDeviceID: "mac-b",
                        name: "Laptop",
                        terminals: []
                    ),
                ],
                status: .connected
            ),
        ], foregroundMacDeviceID: nil)

        store.selectedWorkspaceID = nil

        #expect(store.workspaceListConnectedRefreshTargetMacDeviceID() == nil)
    }

    @Test func destructiveActionsDoNothingWithoutSignedInScope() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Lawrence Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: true
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: false,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )

        await store.forgetMac(macDeviceID: "mac-a")
        await store.updateMacCustomization(
            macDeviceID: "mac-a",
            customName: "Should not write",
            customColor: nil,
            customIcon: nil
        )

        let rows = try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(rows.map(\.macDeviceID) == ["mac-a"])
        #expect(rows.first?.customName == nil)
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
        routes: [CmxAttachRoute]? = nil
    ) throws -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: displayName,
            routes: routes ?? [try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: lastSeenAt,
            isActive: isActive,
            stackUserID: "user-1",
            teamID: "team-a",
            customName: customName,
            customColor: customColor,
            customIcon: customIcon
        )
    }
}
