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
}
