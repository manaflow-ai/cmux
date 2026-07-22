import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellCompositeForgottenMacRefreshTests {
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
        #expect(await store.secondaryAggregationCandidateMacIDs() == ["mac-b"])
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
        #expect(await relaunchedStore.secondaryAggregationCandidateMacIDs() == ["mac-b"])
    }

    @Test func forgettingTeamlessMacSuppressesItAfterTeamSwitch() async throws {
        let team = MutableTeamID("team-a")
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "": [
                    try Self.pairedMac(
                        id: "mac-legacy",
                        displayName: "Legacy Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: true,
                        teamID: nil
                    ),
                ],
                "team-b": [
                    try Self.pairedMac(
                        id: "mac-b",
                        displayName: "Team B Mac",
                        host: "100.82.214.113",
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: false,
                        teamID: "team-b"
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { await team.value },
            forgottenMacStore: InMemoryPairedMacForgottenStore()
        )
        await store.loadPairedMacs()
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-legacy"])

        await store.forgetMac(macDeviceID: "mac-legacy")
        #expect(store.displayPairedMacs.isEmpty)

        await team.set("team-b")
        store.currentTeamDidChange()
        await store.loadPairedMacs()

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-b"])
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

    @Test func secondaryAggregationKeepsOneConnectionPerPhysicalMacWithTaggedSiblings() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        port: 50_901,
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: true,
                        instanceTag: "feature-a"
                    ),
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        port: 50_902,
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false,
                        instanceTag: "feature-b"
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

        #expect(await store.secondaryAggregationCandidateMacIDs() == ["mac-a"])
    }

    @Test func secondaryAggregationUsesFreshUUIDAliasWithoutMergingStaleRoutes() throws {
        let uppercaseUUID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let lowercaseUUID = uppercaseUUID.lowercased()
        let staleRoute = try CmxAttachRoute(
            id: "stale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.10", port: 50_901)
        )
        let freshRoute = try CmxAttachRoute(
            id: "fresh",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.10", port: 50_902)
        )
        let shell = MobileShellComposite(isSignedIn: true)
        let candidates = shell.secondaryAggregationCandidateMacs(from: [
            try Self.pairedMac(
                id: uppercaseUUID,
                displayName: "Stale Studio",
                host: "unused",
                lastSeenAt: Date(timeIntervalSince1970: 10),
                isActive: true,
                customName: "Stale Name",
                routes: [staleRoute],
                instanceTag: "stale"
            ),
            try Self.pairedMac(
                id: lowercaseUUID,
                displayName: "Fresh Studio",
                host: "unused",
                lastSeenAt: Date(timeIntervalSince1970: 20),
                isActive: false,
                customName: "Fresh Name",
                routes: [freshRoute],
                instanceTag: "fresh"
            ),
            try Self.pairedMac(
                id: "Legacy-ID",
                displayName: "Opaque Upper",
                host: "100.64.0.11",
                lastSeenAt: Date(timeIntervalSince1970: 30),
                isActive: false
            ),
            try Self.pairedMac(
                id: "legacy-id",
                displayName: "Opaque Lower",
                host: "100.64.0.12",
                lastSeenAt: Date(timeIntervalSince1970: 40),
                isActive: false
            ),
        ])

        let canonical = try #require(candidates.first { $0.macDeviceID == lowercaseUUID })
        #expect(candidates.count == 3)
        #expect(Set(candidates.map(\.macDeviceID)) == Set([
            lowercaseUUID, "Legacy-ID", "legacy-id",
        ]))
        #expect(canonical.displayName == "Fresh Studio")
        #expect(canonical.customName == "Fresh Name")
        #expect(canonical.instanceTag == "fresh")
        #expect(canonical.routes.map(\.id) == ["fresh"])
        #expect(!canonical.isActive)
    }

    @Test func secondaryAggregationExcludesStaleRecordSharingForegroundIrohEndpoint() async throws {
        let identity = try CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64))
        let liveRoute = try CmxAttachRoute(
            id: "iroh-live",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [])
        )
        let staleRoute = try CmxAttachRoute(
            id: "iroh-stale",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [])
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-live",
                        displayName: "Current Mac",
                        host: "unused",
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: true,
                        routes: [liveRoute],
                        instanceTag: "current"
                    ),
                    try Self.pairedMac(
                        id: "mac-stale",
                        displayName: "Old Mac Name",
                        host: "unused",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false,
                        routes: [staleRoute],
                        instanceTag: "old"
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: SlowIgnoringCancellationTransportFactory(),
                now: { Date(timeIntervalSince1970: 30) },
                supportedRouteKinds: [.iroh]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        store.setWorkspaceStatesForTesting(
            [:],
            foregroundMacDeviceID: "mac-live"
        )

        #expect(await store.secondaryAggregationCandidateMacIDs().isEmpty)
    }

    @Test func secondaryAggregationExcludesInFlightForegroundIrohEndpointBeforeIdentityAdoption() async throws {
        let route = try CmxAttachRoute(
            id: "iroh-live",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "b", count: 64)
                ),
                pathHints: []
            )
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [try Self.pairedMac(
                    id: "mac-saved",
                    displayName: "Saved Mac",
                    host: "unused",
                    lastSeenAt: Date(timeIntervalSince1970: 20),
                    isActive: true,
                    routes: [route],
                    instanceTag: "saved"
                )],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: SlowIgnoringCancellationTransportFactory(),
                now: { Date(timeIntervalSince1970: 30) },
                supportedRouteKinds: [.iroh]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        store.activeRoute = route
        store.setWorkspaceStatesForTesting([:], foregroundMacDeviceID: nil)

        #expect(await store.secondaryAggregationCandidateMacIDs().isEmpty)
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
        instanceTag: String? = nil,
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
            customIcon: customIcon,
            instanceTag: instanceTag
        )
    }
}
