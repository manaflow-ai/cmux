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

        let representative = try #require(store.displayPairedMacs.first)
        await store.hideStoredPairedMacEntries(
            representativeID: representative.id,
            aliasIDs: store.pairedMacAliasIDs(
                for: representative.macDeviceID,
                instanceTag: representative.instanceTag
            )
        )

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-other"])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-other"])
        #expect(store.workspaces.map(\.rpcWorkspaceID.rawValue).isEmpty)
        #expect(try await pairedStore.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        ).map(\.macDeviceID) == ["mac-old", "mac-fresh", "mac-other"])
        #expect(Set(store.hiddenComputers.map(\.macDeviceID)) == Set(["mac-old", "mac-fresh"]))
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

    @Test func switchRestoreTargetUsesLiveForegroundInsteadOfPersistedActiveMac() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-live",
                        displayName: "Live Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 30),
                        isActive: false
                    ),
                    try Self.pairedMac(
                        id: "mac-stale-active",
                        displayName: "Stale Active Mac",
                        host: "100.82.214.113",
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: true
                    ),
                    try Self.pairedMac(
                        id: "mac-target",
                        displayName: "Target Mac",
                        host: "100.82.214.114",
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
        let storeMacs = try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a")

        let restoreTarget = store.previousForegroundMacForSwitchRestore(
            previousForegroundMacDeviceID: "mac-live",
            switchingTo: "mac-target",
            storeMacs: storeMacs
        )

        #expect(restoreTarget?.macDeviceID == "mac-live")
    }

    @Test func presenceRouteWriteFinishingAfterHideKeepsRowFreshAndHidden() async throws {
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
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: true,
                        routes: [oldRoute]
                    ),
                ],
            ],
            blockedTeams: []
        )
        await pairedStore.gateUpsert(macDeviceID: "mac-a")
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()

        store.applyPresenceUpdate(
            .online(PresenceInstance(
                deviceId: "mac-a",
                tag: "default",
                platform: "mac",
                online: true,
                lastSeenAt: 1_000,
                routes: [freshRoute]
            )),
            scope: MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0)
        )
        await pairedStore.waitUntilUpsertStarted(macDeviceID: "mac-a")
        await store.hideMac(macDeviceID: "mac-a")
        await pairedStore.releaseUpsert(macDeviceID: "mac-a")
        await store.pushedRouteSyncTask?.value

        let retained = try #require(try await pairedStore.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        ).first)
        #expect(retained.routes == [freshRoute])
        #expect(store.pairedMacs.isEmpty)
        #expect(store.displayPairedMacs.isEmpty)
        #expect(store.hiddenComputers.map(\.macDeviceID) == ["mac-a"])
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
        await store.pushedRouteSyncTask?.value

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

    @Test
    func physicalAliasIndexJoinsRenamedRowsByIrohAuthority() throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "b", count: 64)
        )
        let route = try CmxAttachRoute(
            id: "shared-iroh-authority",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [])
        )
        let oldAlias = try Self.pairedMac(
            id: "mac-old",
            displayName: "Old Name",
            host: "unused",
            lastSeenAt: .distantPast,
            isActive: false,
            routes: [route]
        )
        let representative = try Self.pairedMac(
            id: "mac-new",
            displayName: "New Name",
            host: "unused",
            lastSeenAt: Date(),
            isActive: false,
            routes: [route]
        )

        let aliases = physicalMacAliasCanonicalIDsByCanonicalID(
            in: [oldAlias, representative],
            supportedKinds: [.iroh],
            preferNonLoopback: true
        )

        #expect(aliases["mac-old"] == ["mac-old", "mac-new"])
        #expect(aliases["mac-new"] == ["mac-old", "mac-new"])
    }

    @Test
    func siblingBuildsWithTheSameDialEndpointRemainSeparateComputers() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Lawrence Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: true,
                        instanceTag: "stable"
                    ),
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Lawrence Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false,
                        instanceTag: "nightly"
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

        #expect(Set(store.displayPairedMacs.map(\.id)) == Set([
            MobilePairedMac.pairingID(macDeviceID: "mac-a", instanceTag: "stable"),
            MobilePairedMac.pairingID(macDeviceID: "mac-a", instanceTag: "nightly"),
        ]))
        #expect(store.pairedMacAliasIDs(for: "mac-a", instanceTag: "stable") == ["mac-a"])
        #expect(store.pairedMacAliasIDs(for: "mac-a", instanceTag: "nightly") == ["mac-a"])
    }

    @Test
    func explicitTransportModesKeepSameIrohEndpointRowsSeparate() throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "c", count: 64)
        )
        let route = try CmxAttachRoute(
            id: "shared-iroh",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [])
        )
        let lan = try Self.pairedMac(
            id: "mac-lan",
            displayName: "Shared Mac",
            host: "unused",
            lastSeenAt: Date(timeIntervalSince1970: 10),
            isActive: false,
            routes: [route],
            connectionMethodRawValue: MobileConnectionMethod.lan.rawValue
        )
        let tailscale = try Self.pairedMac(
            id: "mac-tailscale",
            displayName: "Shared Mac",
            host: "unused",
            lastSeenAt: Date(timeIntervalSince1970: 20),
            isActive: false,
            routes: [route],
            connectionMethodRawValue: MobileConnectionMethod.tailscale.rawValue
        )

        let coalesced = MobileShellComposite.coalescePairedMacsByIrohEndpointAuthority(
            [lan, tailscale],
            supportedKinds: [.iroh],
            preferNonLoopback: true
        )

        #expect(Set(coalesced.map(\.macDeviceID)) == ["mac-lan", "mac-tailscale"])
    }

    @Test func scopedActionsDoNothingWithoutSignedInScope() async throws {
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

        await store.hideMac(macDeviceID: "mac-a")
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
        instanceTag: String? = nil,
        customName: String? = nil,
        customColor: String? = nil,
        customIcon: String? = nil,
        routes: [CmxAttachRoute]? = nil,
        connectionMethodRawValue: String? = nil
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
            customIcon: customIcon,
            instanceTag: instanceTag,
            connectionMethodRawValue: connectionMethodRawValue
        )
    }
}
