import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellCompositeForgetMacTests {
    @Test func forgettingLastVisibleMacClearsSavedMacHint() async throws {
        let defaultsSuiteName = "forget-last-mac-hint-\(UUID().uuidString)"
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

        await store.forgetMac(macDeviceID: "mac-a")

        #expect(store.pairedMacs.isEmpty)
        #expect(store.displayPairedMacs.isEmpty)
        #expect(!store.hasKnownPairedMac)
    }

    @Test func forgetStoredMacRemovesOnlyExactAliasRow() async throws {
        let defaultsSuiteName = "forget-exact-alias-hint-\(UUID().uuidString)"
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
                        isActive: false
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

        await store.forgetStoredMac(macDeviceID: "mac-old")

        #expect(try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a").map(\.macDeviceID) == ["mac-fresh", "mac-other"])
        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-fresh", "mac-other"])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-fresh", "mac-other"])
        #expect(store.hasKnownPairedMac)
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
