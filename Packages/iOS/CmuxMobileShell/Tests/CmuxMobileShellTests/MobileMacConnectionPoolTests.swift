import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileMacConnectionPoolTests {
    @Test func controlTopicsCarryAggregateStateWithoutTerminalRenderTraffic() {
        #expect(SecondaryMacSubscription.eventTopics.contains("workspace.updated"))
        #expect(!SecondaryMacSubscription.eventTopics.contains("mobile.sync.delta"))
        #expect(SecondaryMacSubscription.eventTopics.contains("notification.feed.changed"))
        #expect(!SecondaryMacSubscription.eventTopics.contains {
            $0.hasPrefix("terminal.")
        })
    }

    @Test func rpcTimeoutsRemainRetryableWithoutRetryingAuthorityFailures() {
        #expect(secondaryControlAttemptIsTransient(
            MobileShellConnectionError.rpcError(
                "request_timeout",
                "request timed out"
            )
        ))
        #expect(secondaryControlAttemptIsTransient(
            MobileShellConnectionError.rpcError(
                "server_busy",
                "server is busy"
            )
        ))
        #expect(!secondaryControlAttemptIsTransient(
            MobileShellConnectionError.rpcError(
                "unauthorized",
                "not authorized"
            )
        ))
        #expect(!secondaryControlAttemptIsTransient(
            MobileShellConnectionError.rpcError(
                "method_not_found",
                "unsupported"
            )
        ))
        #expect(!secondaryControlAttemptIsTransient(
            MobileShellConnectionError.rpcError(
                "build_incompatible",
                "upgrade required"
            )
        ))
    }

    @Test func malformedTicketsAndRoutesDoNotRetryForever() {
        let decodingError = DecodingError.dataCorrupted(.init(
            codingPath: [],
            debugDescription: "invalid ticket"
        ))

        #expect(!secondaryControlAttemptIsTransient(
            decodingError
        ))
        #expect(!secondaryControlAttemptIsTransient(
            CmxNetworkByteTransportError.unsupportedRouteKind(.websocket)
        ))
        #expect(!secondaryControlAttemptIsTransient(
            CancellationError()
        ))
        #expect(secondaryControlAttemptIsTransient(
            MobileShellConnectionError.routeCleanupBlocked
        ))
    }

    @Test func networkTransportFailuresRemainRetryable() {
        #expect(secondaryControlAttemptIsTransient(
            CmxNetworkByteTransportError.connectionTimedOut
        ))
        #expect(secondaryControlAttemptIsTransient(
            URLError(.networkConnectionLost)
        ))
    }

    @Test func presenceLimitsControlPoolCandidatesToOnlinePairedMacs() throws {
        let store = MobileShellComposite(
            isSignedIn: false,
            presence: IdlePresence()
        )
        let online = try Self.pairedMac(id: "mac-online", instanceTag: "tag-online")
        let offline = try Self.pairedMac(id: "mac-offline", instanceTag: "tag-offline")
        store.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: online.macDeviceID,
                    tag: "tag-online",
                    online: true
                ),
                Self.instance(
                    deviceID: offline.macDeviceID,
                    tag: "tag-offline",
                    online: false
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        let candidates = store.secondaryAggregationCandidateMacs(
            from: [online, offline]
        )

        #expect(candidates.map(\.macDeviceID) == ["mac-online"])
    }

    @Test func unknownPresenceKeepsCandidatesInsideBoundedPool() throws {
        let shell = MobileShellComposite(
            isSignedIn: false,
            presence: IdlePresence()
        )
        let mac = try Self.pairedMac(
            id: "mac-before-snapshot",
            instanceTag: "tag-before-snapshot"
        )

        let candidates = shell.secondaryAggregationCandidateMacs(
            from: [mac]
        )

        #expect(candidates.map(\.macDeviceID) == ["mac-before-snapshot"])
    }

    @Test func authoritativeEmptyPresenceExcludesUnknownMacs() throws {
        let shell = MobileShellComposite(
            isSignedIn: false,
            presence: IdlePresence()
        )
        let mac = try Self.pairedMac(
            id: "mac-absent-after-snapshot",
            instanceTag: "tag-absent-after-snapshot"
        )
        shell.applyPresenceUpdate(
            Self.snapshot([]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        let candidates = shell.secondaryAggregationCandidateMacs(from: [mac])

        #expect(candidates.isEmpty)
    }

    @Test func inFlightRecoveryTargetIsExcludedFromSecondaryAggregation() throws {
        let shell = MobileShellComposite(
            isSignedIn: false,
            presence: IdlePresence()
        )
        let mac = try Self.pairedMac(
            id: "mac-recovering",
            instanceTag: "tag-recovering"
        )
        // A bounded redial records the recovery target through the live
        // foreground assignment, then clears the foreground context before
        // dialing. The Mac being redialed must not become a "secondary"
        // aggregation candidate in that window: the duplicate
        // background-control session would have to be drained by the very
        // redial that is trying to reconnect it.
        shell.foregroundMacDeviceID = mac.macDeviceID
        shell.foregroundMacDeviceID = nil
        shell.isReconnectingStoredMac = true

        #expect(shell.secondaryAggregationCandidateMacs(from: [mac]).isEmpty)

        // Once the reconnect attempt settles the Mac is aggregable again.
        shell.isReconnectingStoredMac = false
        #expect(shell.secondaryAggregationCandidateMacs(from: [mac])
            .map(\.macDeviceID) == [mac.macDeviceID])
    }

    @Test func onlineAliasKeepsLogicalMacInPool() async throws {
        let route = try CmxAttachRoute(
            id: "alias-route",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 50_922)
        )
        func paired(_ id: String, seenAt: Date) -> MobilePairedMac {
            MobilePairedMac(
                macDeviceID: id,
                displayName: "Alias Mac",
                routes: [route],
                createdAt: .distantPast,
                lastSeenAt: seenAt,
                isActive: false,
                stackUserID: "user-1",
                teamID: "team-1",
                instanceTag: "alias-tag"
            )
        }
        let oldAlias = paired("mac-old-alias", seenAt: .distantPast)
        let representative = paired("mac-new-alias", seenAt: Date())
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-1": [oldAlias, representative],
            ],
            blockedTeams: []
        )
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: LivenessHostRouter(),
                    box: TransportBox()
                ),
                now: { Date() },
                supportedRouteKinds: [.tailscale]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        await shell.loadPairedMacs()
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: oldAlias.macDeviceID,
                    tag: "alias-tag",
                    online: true
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        let candidates = shell.secondaryAggregationCandidateMacs(
            from: [oldAlias, representative]
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.macDeviceID == representative.macDeviceID)
    }

    @Test func onlineIrohAliasSelectsCurrentAuthenticatedIdentity() throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let route = try CmxAttachRoute(
            id: "renamed-iroh-route",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [])
        )
        func paired(
            id: String,
            displayName: String,
            instanceTag: String,
            seenAt: Date
        ) -> MobilePairedMac {
            MobilePairedMac(
                macDeviceID: id,
                displayName: displayName,
                routes: [route],
                createdAt: .distantPast,
                lastSeenAt: seenAt,
                isActive: false,
                stackUserID: "user-1",
                teamID: "team-1",
                instanceTag: instanceTag
            )
        }
        let historicalAlias = paired(
            id: "mac-before-rename",
            displayName: "Old Name",
            instanceTag: "old-tag",
            seenAt: .distantPast
        )
        let currentIdentity = paired(
            id: "mac-after-rename",
            displayName: "New Name",
            instanceTag: "new-tag",
            seenAt: Date()
        )
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: LivenessHostRouter(),
                    box: TransportBox()
                ),
                now: { Date() },
                supportedRouteKinds: [.iroh]
            ),
            isSignedIn: false,
            presence: IdlePresence()
        )
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: historicalAlias.macDeviceID,
                    tag: "old-tag",
                    online: true
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        let candidates = shell.secondaryAggregationCandidateMacs(
            from: [historicalAlias, currentIdentity]
        )

        #expect(candidates.map(\.macDeviceID) == [
            currentIdentity.macDeviceID,
        ])
    }

    @Test func authenticatedIrohAliasPublishesAgainstHistoricalPresence()
        async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "b", count: 64)
        )
        let route = try CmxAttachRoute(
            id: "authenticated-renamed-iroh-route",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [])
        )
        func paired(
            id: String,
            displayName: String,
            instanceTag: String,
            seenAt: Date
        ) -> MobilePairedMac {
            MobilePairedMac(
                macDeviceID: id,
                displayName: displayName,
                routes: [route],
                createdAt: .distantPast,
                lastSeenAt: seenAt,
                isActive: false,
                stackUserID: "user-1",
                teamID: "team-1",
                instanceTag: instanceTag
            )
        }
        let historicalAlias = paired(
            id: "mac-auth-before-rename",
            displayName: "Old Name",
            instanceTag: "old-tag",
            seenAt: .distantPast
        )
        let currentIdentity = paired(
            id: "mac-auth-after-rename",
            displayName: "New Name",
            instanceTag: "new-tag",
            seenAt: Date()
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-1": [historicalAlias, currentIdentity],
            ],
            blockedTeams: []
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: currentIdentity.macDeviceID,
            instanceTag: currentIdentity.instanceTag,
            displayName: currentIdentity.displayName
        )
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() },
                supportedRouteKinds: [.iroh]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        await shell.loadPairedMacs()
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: historicalAlias.macDeviceID,
                    tag: historicalAlias.instanceTag ?? "",
                    online: true
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(currentIdentity)]?.authenticatedInstanceTag == currentIdentity.instanceTag
                && shell.workspacesByMac[MacPairingKey(currentIdentity)]?.status == .connected
        })

        shell.secondaryMacSubscriptions[MacPairingKey(currentIdentity)]?.cancel()
    }

    @Test func physicalAliasReplacementRetiresStaleAggregateSnapshots()
        async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "c", count: 64)
        )
        let route = try CmxAttachRoute(
            id: "aggregate-alias-replacement-route",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [])
        )
        let historicalAlias = MobilePairedMac(
            macDeviceID: "mac-aggregate-before-rename",
            displayName: "Old Aggregate Mac",
            routes: [route],
            createdAt: .distantPast,
            lastSeenAt: .distantPast,
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            instanceTag: "old-aggregate-tag"
        )
        let currentIdentity = MobilePairedMac(
            macDeviceID: "mac-aggregate-after-rename",
            displayName: "New Aggregate Mac",
            routes: [route],
            createdAt: Date(),
            lastSeenAt: Date(),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            instanceTag: "new-aggregate-tag"
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-1": [historicalAlias],
            ],
            blockedTeams: []
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: historicalAlias.macDeviceID,
            instanceTag: historicalAlias.instanceTag,
            displayName: historicalAlias.displayName
        )
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() },
                supportedRouteKinds: [.iroh]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        await shell.loadPairedMacs()
        let scope = MobileShellScopeSnapshot(
            userID: "user-1",
            teamID: "team-1",
            generation: 0
        )
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: historicalAlias.macDeviceID,
                    tag: historicalAlias.instanceTag ?? "",
                    online: true
                ),
            ]),
            scope: scope
        )
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(historicalAlias)] != nil
        })
        shell.workspacesByMac[MacPairingKey(historicalAlias)] =
            MacWorkspaceState(
                macDeviceID: historicalAlias.macDeviceID,
                displayName: historicalAlias.displayName,
                status: .connected
            )
        shell.notificationFeedKnownRevisionsByMac[
            MacPairingKey(historicalAlias).pairingID
        ] = 7
        shell.notificationFeedSnapshotsByMac[MacPairingKey(historicalAlias).pairingID] =
            NotificationFeedMacSnapshot(revision: 7, items: [])

        try await pairedStore.upsert(
            macDeviceID: currentIdentity.macDeviceID,
            displayName: currentIdentity.displayName,
            routes: currentIdentity.routes,
            instanceTag: currentIdentity.instanceTag,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        await router.setHostIdentity(
            deviceID: currentIdentity.macDeviceID,
            instanceTag: currentIdentity.instanceTag,
            displayName: currentIdentity.displayName
        )
        await shell.refreshSecondaryMacWorkspaces()

        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(historicalAlias)] == nil
                && shell.secondaryMacSubscriptions[MacPairingKey(currentIdentity)] != nil
        })
        #expect(shell.workspacesByMac[MacPairingKey(historicalAlias)] == nil)
        #expect(
            shell.notificationFeedSnapshotsByMac[
                MacPairingKey(historicalAlias).pairingID
            ] == nil
        )
        #expect(
            shell.notificationFeedKnownRevisionsByMac[
                MacPairingKey(historicalAlias).pairingID
            ] == nil
        )

        shell.secondaryMacSubscriptions[MacPairingKey(currentIdentity)]?.cancel()
    }

    @Test func fullStorePassPrunesDeletedOfflineAggregateSnapshots()
        async {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-1": [],
            ],
            blockedTeams: []
        )
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: LivenessHostRouter(),
                    box: TransportBox()
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        let deletedMacID = "mac-deleted-while-offline"
        shell.workspacesByMac[deletedMacID.pairingKey] = MacWorkspaceState(
            macDeviceID: deletedMacID,
            displayName: "Deleted Mac",
            status: .unavailable
        )
        shell.notificationFeedKnownRevisionsByMac[deletedMacID] = 9
        shell.notificationFeedSuccessfulMacIDs.insert(deletedMacID)
        shell.notificationFeedSnapshotsByMac[deletedMacID] =
            NotificationFeedMacSnapshot(revision: 9, items: [])

        await shell.refreshSecondaryMacWorkspaces()

        #expect(shell.workspacesByMac[deletedMacID.pairingKey] == nil)
        #expect(shell.notificationFeedSnapshotsByMac[deletedMacID] == nil)
        #expect(shell.notificationFeedKnownRevisionsByMac[deletedMacID] == nil)
        #expect(!shell.notificationFeedSuccessfulMacIDs.contains(deletedMacID))
    }

    @Test func failedFullStorePassPreservesSnapshotsAndRetriesFullLoad()
        async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-1": [],
            ],
            blockedTeams: []
        )
        await pairedStore.failNextLoadAll()
        let clock = ControlPoolManualClock()
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: LivenessHostRouter(),
                    box: TransportBox()
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" },
            controlPlaneSchedulingClock: clock
        )
        let retainedMacID = "mac-retained-after-load-failure"
        shell.workspacesByMac[retainedMacID.pairingKey] = MacWorkspaceState(
            macDeviceID: retainedMacID,
            displayName: "Retained Mac",
            status: .unavailable
        )
        shell.notificationFeedKnownRevisionsByMac[retainedMacID] = 11
        shell.notificationFeedSnapshotsByMac[retainedMacID] =
            NotificationFeedMacSnapshot(revision: 11, items: [])

        await shell.refreshSecondaryMacWorkspaces()

        #expect(shell.pairedMacLoadState == .failed)
        #expect(shell.workspacesByMac[retainedMacID.pairingKey] != nil)
        #expect(shell.notificationFeedSnapshotsByMac[retainedMacID] != nil)
        #expect(shell.secondaryAggregationRetryTask != nil)
        #expect(shell.secondaryAggregationRetryNeedsFullRefresh)
        #expect(try await pollUntil { clock.sleeperCount == 1 })

        clock.advance(by: .seconds(2))
        #expect(try await pollUntil {
            shell.pairedMacLoadState == .loaded
                && shell.workspacesByMac[retainedMacID.pairingKey] == nil
                && shell.notificationFeedSnapshotsByMac[retainedMacID] == nil
        })
    }

    @Test func coldStartStoreFailureRetriesWithoutCachedMacIDs()
        async throws {
        let route = try CmxAttachRoute(
            id: "cold-store-retry-route",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_590)
        )
        let pairedMac = MobilePairedMac(
            macDeviceID: "mac-cold-store-retry",
            displayName: "Cold Store Retry Mac",
            routes: [route],
            createdAt: .distantPast,
            lastSeenAt: Date(),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            instanceTag: "cold-store-tag"
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-1": [pairedMac],
            ],
            blockedTeams: []
        )
        await pairedStore.failNextLoadAll()
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: pairedMac.macDeviceID,
            instanceTag: pairedMac.instanceTag,
            displayName: pairedMac.displayName
        )
        let clock = ControlPoolManualClock()
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" },
            controlPlaneSchedulingClock: clock
        )

        await shell.refreshSecondaryMacWorkspaces()

        #expect(shell.secondaryAggregationRetryMacIDs.isEmpty)
        #expect(shell.secondaryAggregationRetryNeedsFullRefresh)
        #expect(shell.secondaryAggregationRetryTask != nil)
        #expect(try await pollUntil { clock.sleeperCount == 1 })

        clock.advance(by: .seconds(2))
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(pairedMac)] != nil
        })
        #expect(shell.pairedMacLoadState == .loaded)

        shell.secondaryMacSubscriptions[MacPairingKey(pairedMac)]?.cancel()
    }

    @Test func publicationStoreFailureRetriesAsTransient()
        async throws {
        let route = try CmxAttachRoute(
            id: "publication-store-retry-route",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_591)
        )
        let pairedMac = MobilePairedMac(
            macDeviceID: "mac-publication-store-retry",
            displayName: "Publication Store Retry Mac",
            routes: [route],
            createdAt: .distantPast,
            lastSeenAt: Date(),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            instanceTag: "publication-store-tag"
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-1": [pairedMac],
            ],
            blockedTeams: []
        )
        await pairedStore.failLoadAll(call: 2)
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: pairedMac.macDeviceID,
            instanceTag: pairedMac.instanceTag,
            displayName: pairedMac.displayName
        )
        let clock = ControlPoolManualClock()
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" },
            controlPlaneSchedulingClock: clock
        )

        await shell.refreshSecondaryMacWorkspaces()

        #expect(
            shell.secondaryMacSubscriptions[MacPairingKey(pairedMac)] == nil
        )
        #expect(shell.secondaryAggregationRetryMacIDs == [
            pairedMac.macDeviceID,
        ])
        #expect(shell.secondaryAggregationRetryTask != nil)
        #expect(try await pollUntil { clock.sleeperCount == 1 })

        clock.advance(by: .seconds(2))
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(pairedMac)] != nil
        })

        shell.secondaryMacSubscriptions[MacPairingKey(pairedMac)]?.cancel()
    }

    @Test func refreshAuthorityStoreFailurePreservesWarmControlConnection()
        async throws {
        let route = try CmxAttachRoute(
            id: "refresh-authority-store-failure",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_592)
        )
        let pairedMac = MobilePairedMac(
            macDeviceID: "mac-refresh-authority-store-failure",
            displayName: "Refresh Authority Mac",
            routes: [route],
            createdAt: .distantPast,
            lastSeenAt: Date(),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            instanceTag: "refresh-authority-tag"
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-1": [pairedMac]],
            blockedTeams: []
        )
        await pairedStore.failLoadAll(call: 2)
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: pairedMac.macDeviceID,
            instanceTag: pairedMac.instanceTag,
            displayName: pairedMac.displayName
        )
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: pairedMac.macDeviceID,
            macDisplayName: pairedMac.displayName,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let clock = ControlPoolManualClock()
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" },
            controlPlaneSchedulingClock: clock
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: pairedMac.macDeviceID,
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: pairedMac.instanceTag,
            authenticatedInstanceTag: pairedMac.instanceTag,
            supportedHostCapabilities: ["terminal.render_grid.v1"],
            actionCapabilities: .none,
            displayName: pairedMac.displayName
        )
        shell.secondaryMacSubscriptions[MacPairingKey(pairedMac)] =
            subscription
        shell.workspacesByMac[MacPairingKey(pairedMac)] = MacWorkspaceState(
            macDeviceID: pairedMac.macDeviceID,
            displayName: pairedMac.displayName,
            status: .connected
        )

        await shell.refreshSecondaryMacWorkspaces()

        #expect(
            shell.secondaryMacSubscriptions[MacPairingKey(pairedMac)]
                === subscription
        )
        #expect(
            shell.workspacesByMac[MacPairingKey(pairedMac)]?.status
                == .connected
        )
        #expect(shell.secondaryAggregationRetryTask != nil)
        #expect(shell.secondaryAggregationRetryMacIDs == [
            pairedMac.macDeviceID,
        ])
        subscription.cancel()
    }

    @Test
    func targetedOfflineAliasRetiresRepresentativeControlConnection()
        async throws {
        let route = try CmxAttachRoute(
            id: "offline-alias-route",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_589)
        )
        func paired(_ id: String, seenAt: Date) -> MobilePairedMac {
            MobilePairedMac(
                macDeviceID: id,
                displayName: "Alias Mac",
                routes: [route],
                createdAt: .distantPast,
                lastSeenAt: seenAt,
                isActive: false,
                stackUserID: "user-1",
                teamID: "team-1",
                instanceTag: "alias-tag"
            )
        }
        let oldAlias = paired("mac-old-offline-alias", seenAt: .distantPast)
        let representative = paired(
            "mac-new-offline-alias",
            seenAt: Date()
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-1": [oldAlias, representative],
            ],
            blockedTeams: []
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: representative.macDeviceID,
            instanceTag: "alias-tag",
            displayName: "Alias Mac"
        )
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() },
                supportedRouteKinds: [.debugLoopback]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        await shell.loadPairedMacs()
        let scope = MobileShellScopeSnapshot(
            userID: "user-1",
            teamID: "team-1",
            generation: 0
        )
        let onlineInstance = Self.instance(
            deviceID: oldAlias.macDeviceID,
            tag: "alias-tag",
            online: true
        )
        shell.applyPresenceUpdate(
            Self.snapshot([onlineInstance]),
            scope: scope
        )
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(representative)] != nil
        })

        shell.applyPresenceUpdate(
            .offline(
                Self.instance(
                    deviceID: oldAlias.macDeviceID,
                    tag: "alias-tag",
                    online: false
                ),
                reason: .goodbye
            ),
            scope: scope
        )

        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(representative)] == nil
        })
        #expect(
            shell.workspacesByMac[MacPairingKey(representative)]?.status
                == .unavailable
        )
        shell.secondaryMacSubscriptions[MacPairingKey(representative)]?.cancel()
    }

    @Test func teardownCancelsDeferredPostRouteAggregation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "deferred-route-teardown",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-deferred",
            displayName: "Deferred Mac",
            routes: [route],
            instanceTag: "deferred-tag",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "mac-deferred",
            instanceTag: "deferred-tag",
            displayName: "Deferred Mac"
        )
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        let scope = MobileShellScopeSnapshot(
            userID: "user-1",
            teamID: "team-1",
            generation: 0
        )
        let gate = ControlPoolRouteSyncGate()
        let routeSyncTask = Task { await gate.wait() }
        shell.pushedRouteSyncTask = routeSyncTask
        shell.pushedRouteSyncOperationID = UUID()
        shell.applyPresenceUpdate(
            .online(Self.instance(
                deviceID: "mac-deferred",
                tag: "deferred-tag",
                online: true
            )),
            scope: scope
        )

        shell.clearRemoteConnectionContext()
        await gate.release()
        await routeSyncTask.value

        let reopenedPool = try await pollUntil(attempts: 50) {
            await router.count(of: "mobile.host.status") > 0
        }
        #expect(!reopenedPool)
        #expect(shell.secondaryMacSubscriptions.isEmpty)
    }

    @Test func offlinePresenceWinsAgainstInFlightControlDial() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "presence-dial-race",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-racing",
            displayName: "Racing Mac",
            routes: [route],
            instanceTag: "racing-tag",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "mac-racing",
            instanceTag: "racing-tag",
            displayName: "Racing Mac"
        )
        await router.delayHostStatusRequest(number: 1)
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-racing", instanceTag: "racing-tag")] = MacWorkspaceState(
            macDeviceID: "mac-racing",
            displayName: "Racing Mac",
            workspaces: [],
            status: .connected
        )
        let scope = MobileShellScopeSnapshot(
            userID: "user-1",
            teamID: "team-1",
            generation: 0
        )
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: "mac-racing",
                    tag: "racing-tag",
                    online: true
                ),
            ]),
            scope: scope
        )
        #expect(await router.waitForCount(
            of: "mobile.host.status",
            atLeast: 1
        ))
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })

        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: "mac-racing",
                    tag: "racing-tag",
                    online: false
                ),
            ]),
            scope: scope
        )
        for _ in 0 ..< 4 { await Task.yield() }
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-racing", instanceTag: "racing-tag")] == nil)

        await router.releaseAllHeld()
        #expect(try await pollUntil {
            shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-racing", instanceTag: "racing-tag")]?.status == .unavailable
        })
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-racing", instanceTag: "racing-tag")] == nil)
    }

    @Test func fullAndTargetedAggregationShareOnePerMacDial() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "single-flight-dial",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_585)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-single-flight",
            displayName: "Single Flight Mac",
            routes: [route],
            instanceTag: "single-flight-tag",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "mac-single-flight",
            instanceTag: "single-flight-tag",
            displayName: "Single Flight Mac"
        )
        await router.delayHostStatusRequest(number: 1)
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        await shell.loadPairedMacs()

        let fullRefresh = Task { @MainActor in
            await shell.refreshSecondaryMacWorkspaces()
        }
        #expect(await router.waitForCount(
            of: "mobile.host.status",
            atLeast: 1
        ))
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })
        let targetedRefresh = Task { @MainActor in
            await shell.refreshSecondaryMacWorkspaces(
                onlyMacDeviceIDs: ["mac-single-flight"]
            )
        }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(await router.count(of: "mobile.host.status") == 1)

        await router.releaseAllHeld()
        await fullRefresh.value
        await targetedRefresh.value

        #expect(await router.count(of: "mobile.host.status") == 1)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-single-flight", instanceTag: "single-flight-tag")] != nil)
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-single-flight", instanceTag: "single-flight-tag")]?.cancel()
    }

    @Test func foregroundAttachWaitsForAndSupersedesInFlightControlDial()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "foreground-control-race",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_596)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-control-race",
            displayName: "Control Race Mac",
            routes: [route],
            instanceTag: "control-race-tag",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let router = LivenessHostRouter()
        let transportBox = TransportBox()
        await router.setHostIdentity(
            deviceID: "mac-control-race",
            instanceTag: "control-race-tag",
            displayName: "Control Race Mac"
        )
        await router.delayHostStatusRequest(number: 1)
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: transportBox
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        await shell.loadPairedMacs()

        let controlRefresh = Task { @MainActor in
            await shell.refreshSecondaryMacWorkspaces()
        }
        #expect(await router.waitForCount(
            of: "mobile.host.status",
            atLeast: 1
        ))
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })
        let controlTransport = try #require(transportBox.get())
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "mac-control-race",
            macDisplayName: "Control Race Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let foregroundAttach = Task { @MainActor in
            try await shell.connect(
                ticket: ticket,
                allowsStackAuthFallback: true,
                pairedMacDeviceID: "mac-control-race",
                instanceTagExpectation: .require("control-race-tag")
            )
        }
        for _ in 0 ..< 5 { await Task.yield() }

        // Task scheduling may let the foreground send its status request before
        // this test releases the old mocked response. That is safe only after
        // cancellation has closed the control transport, which is the physical
        // overlap the reservation prevents.
        let statusCountBeforeRelease = await router.count(
            of: "mobile.host.status"
        )
        #expect((1 ... 2).contains(statusCountBeforeRelease))
        if statusCountBeforeRelease == 2 {
            #expect(await controlTransport.isClosedForTesting())
        }

        await router.releaseAllHeld()
        _ = try await foregroundAttach.value
        await controlRefresh.value

        #expect(shell.connectionState == .connected)
        #expect(shell.foregroundMacDeviceIDForTesting() == "mac-control-race")
        #expect(shell.secondaryMacSubscriptions[
            MacPairingKey(
                macDeviceID: "mac-control-race",
                instanceTag: "control-race-tag"
            )
        ] == nil)
        #expect(await router.count(of: "mobile.host.status") == 2)
    }

    @Test func warmControlPoolHasStableResourceCap() throws {
        let store = MobileShellComposite(isSignedIn: false)
        let candidateCount =
            MobileShellComposite.maximumWarmControlConnectionCount + 2
        let pairedMacs = try (0 ..< candidateCount).map { index in
            MobilePairedMac(
                macDeviceID: "mac-\(index)",
                displayName: "Mac \(index)",
                routes: [try CmxAttachRoute(
                    id: "route-\(index)",
                    kind: .debugLoopback,
                    endpoint: .hostPort(
                        host: "127.0.0.1",
                        port: 50_000 + index
                    )
                )],
                createdAt: .distantPast,
                lastSeenAt: Date(timeIntervalSince1970: Double(index)),
                isActive: false,
                stackUserID: "user-1",
                teamID: "team-1",
                instanceTag: "tag-\(index)"
            )
        }

        let candidates = store.secondaryAggregationCandidateMacs(
            from: pairedMacs
        )

        #expect(
            candidates.count
                == MobileShellComposite.maximumWarmControlConnectionCount
        )
        #expect(candidates.first?.macDeviceID == "mac-\(candidateCount - 1)")
        #expect(!candidates.contains { $0.macDeviceID == "mac-0" })
    }

    @Test func taggedHostPortAliasOfFocusDoesNotConsumePoolSlot() throws {
        let store = MobileShellComposite(isSignedIn: false)
        let focusedRoute = try CmxAttachRoute(
            id: "focused-route",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 50_400)
        )
        func pairedMac(
            id: String,
            tag: String,
            route: CmxAttachRoute,
            lastSeenAt: Date
        ) -> MobilePairedMac {
            MobilePairedMac(
                macDeviceID: id,
                displayName: id,
                routes: [route],
                createdAt: .distantPast,
                lastSeenAt: lastSeenAt,
                isActive: false,
                stackUserID: "user-1",
                teamID: "team-1",
                instanceTag: tag
            )
        }
        var focused = pairedMac(
            id: "focused-old-id",
            tag: "focused-tag",
            route: focusedRoute,
            lastSeenAt: Date(timeIntervalSince1970: 1)
        )
        var renamedAlias = pairedMac(
            id: "focused-renamed-id",
            tag: "focused-tag",
            route: focusedRoute,
            lastSeenAt: Date(timeIntervalSince1970: 10_000)
        )
        focused.displayName = "Focused Mac"
        renamedAlias.displayName = "Focused Mac"
        let otherMacs = try (0 ..<
            MobileShellComposite.maximumWarmControlConnectionCount
        ).map { index in
            pairedMac(
                id: "other-\(index)",
                tag: "other-tag-\(index)",
                route: try CmxAttachRoute(
                    id: "other-route-\(index)",
                    kind: .debugLoopback,
                    endpoint: .hostPort(
                        host: "127.0.0.1",
                        port: 50_500 + index
                    )
                ),
                lastSeenAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        store.foregroundMacDeviceID = focused.macDeviceID
        store.activeRoute = focusedRoute

        let candidates = store.secondaryAggregationCandidateMacs(
            from: [focused, renamedAlias] + otherMacs
        )

        #expect(candidates.count == otherMacs.count)
        #expect(!candidates.contains {
            $0.macDeviceID == renamedAlias.macDeviceID
        })
        #expect(Set(candidates.map(\.macDeviceID))
            == Set(otherMacs.map(\.macDeviceID)))
    }

    @Test func controlPublicationAtomicallyEnforcesResourceCap() throws {
        let registry = MobileMacConnectionRegistry()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "atomic-control-cap",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 50_811)
        )
        func connectionParts(
            _ macDeviceID: String
        ) throws -> (
            subscription: SecondaryMacSubscription,
            connection: MacConnection
        ) {
            let ticket = try CmxAttachTicket(
                workspaceID: "",
                terminalID: nil,
                macDeviceID: macDeviceID,
                macDisplayName: macDeviceID,
                routes: [route],
                expiresAt: Date().addingTimeInterval(3_600)
            )
            let client = MobileCoreRPCClient(
                runtime: runtime,
                route: route,
                ticket: ticket,
                allowsStackAuthFallback: true
            )
            return (
                SecondaryMacSubscription(
                    macDeviceID: macDeviceID,
                    client: client,
                    route: route,
                    ticket: ticket,
                    supportedHostCapabilities: [],
                    actionCapabilities: .none
                ),
                MacConnection(
                    macDeviceID: macDeviceID,
                    ticket: ticket,
                    route: route,
                    client: client,
                    generation: UUID(),
                    displayName: macDeviceID,
                    instanceTag: nil,
                    supportedHostCapabilities: [],
                    actionCapabilities: .none
                )
            )
        }

        let focus = try connectionParts("mac-focus")
        _ = registry.transitionToFocused(focus.connection)
        var controls: [(
            subscription: SecondaryMacSubscription,
            connection: MacConnection
        )] = []
        for index in 0 ..<
            MobileShellComposite.maximumWarmControlConnectionCount {
            let control = try connectionParts("mac-control-\(index)")
            controls.append(control)
            #expect(registry.insertControlIfAbsent(
                control.subscription,
                maximumControlCount:
                    MobileShellComposite.maximumWarmControlConnectionCount
            ))
        }
        let overflow = try connectionParts("mac-overflow").subscription
        #expect(!registry.insertControlIfAbsent(
            overflow,
            maximumControlCount:
                MobileShellComposite.maximumWarmControlConnectionCount
        ))
        #expect(!registry.transitionToControl(
            focus.subscription,
            replacing: focus.connection,
            maximumControlCount:
                MobileShellComposite.maximumWarmControlConnectionCount
        ))
        #expect(
            registry.controlSubscriptions.count
                == MobileShellComposite.maximumWarmControlConnectionCount
        )

        #expect(registry.exchangePromotedControlForDemotedFocus(
            promotedControl: controls[0].subscription,
            demotedControl: focus.subscription,
            replacing: focus.connection
        ))
        _ = registry.transitionToFocused(controls[0].connection)
        #expect(
            registry.controlSubscriptions.count
                == MobileShellComposite.maximumWarmControlConnectionCount
        )
        #expect(registry.snapshots.filter { $0.role == .focused }.count == 1)
        for control in controls {
            control.subscription.cancel()
        }
        overflow.cancel()
        focus.subscription.cancel()
    }

    @Test func removingControlCapabilityLeavesSharedFocusRegistered() throws {
        let route = try CmxAttachRoute(
            id: "exact-control-removal",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 57_100)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "control-removal-workspace",
            terminalID: "control-removal-terminal",
            macDeviceID: "control-removal-mac",
            macDisplayName: "Control removal Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox()
            ),
            now: { Date() }
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let connection = MacConnection(
            macDeviceID: ticket.macDeviceID,
            ticket: ticket,
            route: route,
            client: client,
            generation: UUID(),
            displayName: ticket.macDisplayName,
            instanceTag: "control-removal-tag",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: ticket.macDeviceID,
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: connection.storedInstanceTag,
            authenticatedInstanceTag: connection.authenticatedInstanceTag,
            supportedHostCapabilities: [],
            actionCapabilities: .none,
            displayName: ticket.macDisplayName
        )
        let registry = MobileMacConnectionRegistry()

        #expect(registry.transitionToFocused(connection) == nil)
        #expect(registry.installControlAlongsideFocus(
            subscription,
            replacing: connection
        ))
        #expect(registry.removeControlSubscription(ifMatching: subscription))
        #expect(registry.controlSubscription(for: connection.ownerKey) == nil)
        #expect(registry.focusedConnection(for: connection.ownerKey)?.client === client)
        #expect(registry.sessionCount == 1)

        subscription.cancel()
    }

    @Test func targetedPresenceRefreshUsesCachedPerMacIndex() async throws {
        let records = try (0 ..< 1_000).map { index in
            try Self.pairedMac(
                id: "mac-\(index)",
                instanceTag: "tag-\(index)"
            )
        }
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-1": records],
            blockedTeams: []
        )
        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        await shell.loadPairedMacs()
        await pairedStore.resetLoadAllCount()

        await shell.refreshSecondaryMacWorkspaces(
            onlyMacDeviceIDs: ["mac-999"],
            allowsNewConnections: false
        )

        #expect(await pairedStore.currentLoadAllCount() == 0)
    }

    @Test func targetedDialRevalidatesStoreAuthorityBeforePublishing()
        async throws {
        let route = try CmxAttachRoute(
            id: "targeted-authority",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let storedA = MobilePairedMac(
            macDeviceID: "mac-targeted",
            displayName: "Targeted Mac",
            routes: [route],
            createdAt: .distantPast,
            lastSeenAt: .distantPast,
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            instanceTag: "tag-a"
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-1": [storedA]],
            blockedTeams: []
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "mac-targeted",
            instanceTag: "tag-a",
            displayName: "Targeted Mac"
        )
        await router.delayHostStatusRequest(number: 1)
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        await shell.loadPairedMacs()
        await pairedStore.resetLoadAllCount()

        let refresh = Task { @MainActor in
            await shell.refreshSecondaryMacWorkspaces(
                onlyMacDeviceIDs: ["mac-targeted"]
            )
        }
        #expect(await router.waitForCount(
            of: "mobile.host.status",
            atLeast: 1
        ))
        try await pairedStore.upsert(
            macDeviceID: "mac-targeted",
            displayName: "Replacement Mac",
            routes: [route],
            instanceTag: "tag-b",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        await router.releaseAllHeld()
        await refresh.value

        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-targeted", instanceTag: "tag-b")] == nil)
        #expect(!shell.liveMacConnections.contains {
            $0.macDeviceID == "mac-targeted"
        })
        #expect(await pairedStore.currentLoadAllCount() == 1)
    }

    @Test func incrementalOfflineEdgeBackfillsFreedControlSlot() throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: false,
            presence: IdlePresence()
        )
        let candidateCount =
            MobileShellComposite.maximumWarmControlConnectionCount + 1
        let pairedMacs = try (0 ..< candidateCount).map {
            try Self.pairedMac(
                id: "mac-\($0)",
                instanceTag: "tag-\($0)"
            )
        }
        shell.applyPresenceUpdate(
            Self.snapshot(pairedMacs.enumerated().map { index, mac in
                Self.instance(
                    deviceID: mac.macDeviceID,
                    tag: mac.instanceTag ?? "",
                    online: index != 0
                )
            }),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )
        for mac in pairedMacs.prefix(
            MobileShellComposite.maximumWarmControlConnectionCount
        ) {
            let route = try #require(mac.routes.first)
            let ticket = try CmxAttachTicket(
                workspaceID: "",
                terminalID: nil,
                macDeviceID: mac.macDeviceID,
                macDisplayName: mac.displayName,
                routes: [route],
                expiresAt: Date().addingTimeInterval(3_600)
            )
            shell.secondaryMacSubscriptions[MacPairingKey(mac)] =
                SecondaryMacSubscription(
                    macDeviceID: mac.macDeviceID,
                    client: MobileCoreRPCClient(
                        runtime: runtime,
                        route: route,
                        ticket: ticket,
                        allowsStackAuthFallback: true
                    ),
                    route: route,
                    ticket: ticket,
                    storedInstanceTag: mac.instanceTag,
                    supportedHostCapabilities: [],
                    actionCapabilities: .none
                )
        }

        let targets = shell.secondaryAggregationTargets(
            from: pairedMacs,
            requestedCanonicalIDs: ["mac-0"]
        )

        #expect(targets.map(\.macDeviceID) == [
            "mac-\(candidateCount - 1)",
        ])
    }

    @Test func incrementalOnlineEdgeDoesNotRetryUnrelatedMissingMacs() throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: false,
            presence: IdlePresence()
        )
        let existing = try Self.pairedMac(
            id: "mac-existing",
            instanceTag: "existing-tag"
        )
        let requested = try Self.pairedMac(
            id: "mac-requested",
            instanceTag: "requested-tag"
        )
        let unrelated = try Self.pairedMac(
            id: "mac-unrelated",
            instanceTag: "unrelated-tag"
        )
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: existing.macDeviceID,
                    tag: existing.instanceTag ?? "",
                    online: true
                ),
                Self.instance(
                    deviceID: requested.macDeviceID,
                    tag: requested.instanceTag ?? "",
                    online: true
                ),
                Self.instance(
                    deviceID: unrelated.macDeviceID,
                    tag: unrelated.instanceTag ?? "",
                    online: true
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )
        let route = try #require(existing.routes.first)
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: existing.macDeviceID,
            macDisplayName: existing.displayName,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        shell.secondaryMacSubscriptions[MacPairingKey(existing)] =
            SecondaryMacSubscription(
                macDeviceID: existing.macDeviceID,
                client: MobileCoreRPCClient(
                    runtime: runtime,
                    route: route,
                    ticket: ticket,
                    allowsStackAuthFallback: true
                ),
                route: route,
                ticket: ticket,
                storedInstanceTag: existing.instanceTag,
                supportedHostCapabilities: [],
                actionCapabilities: .none
            )

        let targets = shell.secondaryAggregationTargets(
            from: [existing, requested, unrelated],
            requestedCanonicalIDs: ["mac-requested"]
        )

        #expect(targets.map(\.macDeviceID) == ["mac-requested"])
    }

    @Test func promotedControlSlotMakesRoomForPreviousFocus() {
        let capacity =
            MobileShellComposite.maximumWarmControlConnectionCount

        #expect(!warmControlPoolHasCapacity(
            currentControlCount: capacity,
            vacatesControlSlot: false
        ))
        #expect(warmControlPoolHasCapacity(
            currentControlCount: capacity,
            vacatesControlSlot: true
        ))
        #expect(!warmControlPoolHasCapacity(
            currentControlCount: capacity + 1,
            vacatesControlSlot: true
        ))
    }

    @Test func onlineTaggedInstanceWinsBeforePhysicalMacCoalescing() throws {
        let store = MobileShellComposite(
            isSignedIn: false,
            presence: IdlePresence()
        )
        let offlinePreferred = try Self.pairedMac(
            id: "shared-mac",
            instanceTag: "offline-active",
            isActive: true
        )
        let onlineAlternative = try Self.pairedMac(
            id: "shared-mac",
            instanceTag: "online-tag"
        )
        store.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: "shared-mac",
                    tag: "offline-active",
                    online: false
                ),
                Self.instance(
                    deviceID: "shared-mac",
                    tag: "online-tag",
                    online: true
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        let candidates = store.secondaryAggregationCandidateMacs(
            from: [offlinePreferred, onlineAlternative]
        )

        #expect(candidates.map(\.instanceTag) == ["online-tag"])
    }

    @Test func globalIrohSupportDoesNotExcludeAuthorizedLegacyTailscaleMac() throws {
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox()
            ),
            now: { Date() },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let shell = MobileShellComposite(runtime: runtime, isSignedIn: false)
        let legacy = try Self.pairedMac(
            id: "legacy-tailscale",
            instanceTag: "legacy"
        )

        let candidates = shell.secondaryAggregationCandidateMacs(from: [legacy])

        #expect(candidates.map(\.macDeviceID) == ["legacy-tailscale"])
    }

    @Test func hostWithoutEventsUsesRefreshOnlyAggregationFallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "refresh-only-control",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-refresh-only",
            displayName: "Refresh-only Mac",
            routes: [route],
            instanceTag: "refresh-only-tag",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "mac-refresh-only",
            instanceTag: "refresh-only-tag",
            displayName: "Refresh-only Mac"
        )
        await router.setCapabilities(["workspace.actions.v1"])
        let clock = ControlPoolManualClock()
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" },
            controlPlaneSchedulingClock: clock
        )
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: "mac-refresh-only",
                    tag: "refresh-only-tag",
                    online: true
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        #expect(await router.waitForCount(
            of: "workspace.list",
            atLeast: 1
        ))
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-refresh-only", instanceTag: "refresh-only-tag")] != nil
                && shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-refresh-only", instanceTag: "refresh-only-tag")]?.status
                    == .connected
        })
        #expect(await router.count(of: "mobile.events.subscribe") == 0)
        #expect(try await pollUntil { clock.sleeperCount == 1 })

        await router.failWorkspaceListRequest(number: 2)
        for tick in 1 ... 3 {
            clock.advance(by: .seconds(20))
            if tick < 3 {
                #expect(try await pollUntil {
                    clock.sleeperCount == 1
                })
                #expect(await router.count(of: "workspace.list") == 1)
            }
        }
        #expect(await router.waitForCount(of: "workspace.list", atLeast: 2))
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-refresh-only", instanceTag: "refresh-only-tag")] == nil
        })
        #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-refresh-only", instanceTag: "refresh-only-tag")]?.status
            == .unavailable)
    }

    @Test func permanentRefreshFailureWaitsForNewPresenceEvidence()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "permanent-refresh-failure",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-permanent-refresh",
            displayName: "Permanent Failure Mac",
            routes: [route],
            instanceTag: "permanent-tag",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let router = LivenessHostRouter()
        let closeGate = LivenessTransportCloseGate()
        await router.setHostIdentity(
            deviceID: "mac-permanent-refresh",
            instanceTag: "permanent-tag",
            displayName: "Permanent Failure Mac"
        )
        await router.setCapabilities(["workspace.actions.v1"])
        let clock = ControlPoolManualClock()
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox(),
                    closeGate: closeGate
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" },
            controlPlaneSchedulingClock: clock,
            connectionHandoffDrainTimeoutNanoseconds: 1_000_000
        )
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: "mac-permanent-refresh",
                    tag: "permanent-tag",
                    online: true
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-permanent-refresh", instanceTag: "permanent-tag")] != nil
                && clock.sleeperCount == 1
        })
        await router.failWorkspaceListRequest(
            number: 2,
            code: "method_not_found"
        )
        for tick in 1 ... 3 {
            clock.advance(by: .seconds(20))
            if tick < 3 {
                #expect(try await pollUntil {
                    clock.sleeperCount == 1
                })
                #expect(await router.count(of: "workspace.list") == 1)
            }
        }

        #expect(await router.waitForCount(of: "workspace.list", atLeast: 2))
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-permanent-refresh", instanceTag: "permanent-tag")] == nil
        })
        #expect(await closeGate.waitUntilCloseStarted())
        #expect(
            shell.secondaryMacDrainReservations[MacPairingKey(macDeviceID: "mac-permanent-refresh", instanceTag: "permanent-tag")]
                != nil
        )
        #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-permanent-refresh", instanceTag: "permanent-tag")]?.status
            == .unavailable)
        #expect(shell.secondaryAggregationRetryTask == nil)
        let workspaceRequests = await router.count(of: "workspace.list")
        clock.advance(by: .seconds(60))
        for _ in 0 ..< 8 { await Task.yield() }
        #expect(await router.count(of: "workspace.list") == workspaceRequests)
        await closeGate.release()
        #expect(try await pollUntil {
            shell.secondaryMacDrainReservations[MacPairingKey(macDeviceID: "mac-permanent-refresh", instanceTag: "permanent-tag")]
                == nil
        })
    }

    @Test func storedAuthorityReplacementDrainsOldControlBeforeRedial()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "authority-replacement",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-authority-replacement",
            displayName: "Authority Replacement Mac",
            routes: [route],
            instanceTag: "tag-a",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "mac-authority-replacement",
            instanceTag: "tag-a",
            displayName: "Authority Replacement Mac"
        )
        let closeGate = LivenessTransportCloseGate()
        let clock = ControlPoolManualClock()
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox(),
                    closeGate: closeGate
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" },
            controlPlaneSchedulingClock: clock,
            connectionHandoffDrainTimeoutNanoseconds: 1_000_000
        )
        await shell.loadPairedMacs()
        await shell.refreshSecondaryMacWorkspaces()
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[
                MacPairingKey(macDeviceID: "mac-authority-replacement", instanceTag: "tag-a")
            ] != nil
        })
        let firstHostStatusCount = await router.count(
            of: "mobile.host.status"
        )

        try await pairedStore.upsert(
            macDeviceID: "mac-authority-replacement",
            displayName: "Authority Replacement Mac",
            routes: [route],
            instanceTag: "tag-b",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        await router.setHostIdentity(
            deviceID: "mac-authority-replacement",
            instanceTag: "tag-b",
            displayName: "Authority Replacement Mac"
        )
        await shell.refreshSecondaryMacWorkspaces()
        #expect(await closeGate.waitUntilCloseStarted())

        #expect(
            await router.count(of: "mobile.host.status")
                == firstHostStatusCount
        )
        #expect(
            shell.secondaryMacSubscriptions[
                MacPairingKey(macDeviceID: "mac-authority-replacement", instanceTag: "tag-a")
            ] == nil
        )
        #expect(
            shell.secondaryMacDrainReservations[
                MacPairingKey(macDeviceID: "mac-authority-replacement", instanceTag: "tag-a")
            ] != nil
        )
        #expect(shell.secondaryAggregationRetryTask == nil)

        await closeGate.release()
        #expect(try await pollUntil {
            shell.secondaryAggregationRetryTask != nil
        })
        clock.advance(by: .seconds(2))
        #expect(await router.waitForCount(
            of: "mobile.host.status",
            atLeast: firstHostStatusCount + 1
        ))
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[
                MacPairingKey(macDeviceID: "mac-authority-replacement", instanceTag: "tag-b")
            ] != nil
        })
    }

    @Test func repeatedDrainReservationReusesOneTransportCloseOperation()
        async throws {
        let router = LivenessHostRouter()
        let closeGate = LivenessTransportCloseGate()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox(),
                closeGate: closeGate
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "reused-drain",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-reused-drain",
            macDisplayName: "Drain Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        _ = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.host.status",
                params: [:]
            )
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: ticket.macDeviceID,
            client: client,
            route: route,
            ticket: ticket,
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        let shell = MobileShellComposite(runtime: runtime, isSignedIn: true)
        shell.secondaryMacSubscriptions[subscription.ownerKey] = subscription
        shell.macSwitchAttemptID = UUID()

        #expect(shell.beginSecondaryMacDrainReservation(subscription))
        #expect(await closeGate.waitUntilCloseStarted())
        let first = try #require(subscription.transportDrainOperation)
        let retry = shell.secondaryMacTransportDrainOperation(subscription)

        #expect(first === retry)
        #expect(shell.secondaryMacDrainReservations[subscription.ownerKey]
            === subscription)
        let firstTimedWait = await first.wait(nanoseconds: 1_000_000)
        #expect(!firstTimedWait)
        #expect(first.pendingWaiterCount == 0)
        let retryTimedWait = await retry.wait(nanoseconds: 1_000_000)
        #expect(!retryTimedWait)
        #expect(retry.pendingWaiterCount == 0)

        await closeGate.release()
        #expect(try await pollUntil {
            subscription.hasCompletedTransportDrain
        })
        shell.macSwitchAttemptID = nil
        shell.finishCompletedSecondaryMacDrainReservations()
        #expect(shell.secondaryMacDrainReservations[subscription.ownerKey] == nil)
    }

    @Test func retryStateCoalescesPoolFailuresAndCapsBackoff() {
        var state = MobileControlPoolRetryState()

        #expect(state.schedule() == .seconds(2))
        #expect(state.schedule() == nil)
        state.fire()
        #expect(state.schedule() == .seconds(4))
        state.fire()
        #expect(state.schedule() == .seconds(8))
        state.fire()
        #expect(state.schedule() == .seconds(16))
        state.fire()
        #expect(state.schedule() == .seconds(32))
        state.fire()
        #expect(state.schedule() == .seconds(60))
        state.fire()
        #expect(state.schedule() == .seconds(60))
        state.fire()
        #expect(state.schedule() == .seconds(60))

        state.reset()
        #expect(state.schedule() == .seconds(2))
    }

    @Test func staleFullPassPreservesNewerTargetedRetryEvidence()
        async {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-1": []],
            blockedTeams: ["team-1"]
        )
        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        let staleFullPass = Task { @MainActor in
            await shell.refreshSecondaryMacWorkspaces()
        }
        await pairedStore.waitUntilLoadStarted(teamID: "team-1")

        shell.scheduleSecondaryAggregationRetry(
            macDeviceIDs: ["mac-newer-targeted-failure"]
        )
        #expect(shell.secondaryAggregationRetryTask != nil)

        await pairedStore.release(teamID: "team-1")
        await staleFullPass.value

        #expect(shell.secondaryAggregationRetryTask != nil)
        #expect(shell.secondaryAggregationRetryMacIDs
            == ["mac-newer-targeted-failure"])
        shell.cancelSecondaryAggregationRetry()
    }

    @Test func staleRetryCompletionCannotClearReplacementTimer() async throws {
        let clock = ControlPoolManualClock()
        let shell = MobileShellComposite(
            isSignedIn: true,
            presence: IdlePresence(),
            controlPlaneSchedulingClock: clock
        )
        shell.scheduleSecondaryAggregationRetry(macDeviceIDs: ["test-retry"])
        #expect(try await pollUntil { clock.sleeperCount == 1 })

        // Wake the old task without yielding the MainActor, then replace it.
        // Its continuation is queued but must not own the new timer's state.
        clock.advance(by: .seconds(2))
        shell.cancelSecondaryAggregationRetry()
        shell.scheduleSecondaryAggregationRetry(macDeviceIDs: ["test-retry"])
        #expect(try await pollUntil { clock.sleeperCount == 1 })
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(shell.secondaryAggregationRetryTask != nil)
        #expect(shell.secondaryAggregationRetryMacIDs == ["test-retry"])
        shell.cancelSecondaryAggregationRetry()
    }

    @Test func sharedCooldownQueuesNewlyOnlineMac() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "suppressed-online",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-new",
            displayName: "New Mac",
            routes: [route],
            instanceTag: "new-tag",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let clock = ControlPoolManualClock()
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: LivenessHostRouter(),
                    box: TransportBox()
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" },
            controlPlaneSchedulingClock: clock
        )
        shell.scheduleSecondaryAggregationRetry(macDeviceIDs: ["test-retry"])
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: "mac-new",
                    tag: "new-tag",
                    online: true
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        #expect(try await pollUntil {
            shell.secondaryAggregationRetryMacIDs.contains("mac-new")
        })
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-new", instanceTag: "new-tag")] == nil)
        shell.cancelSecondaryAggregationRetry()
    }

    @Test func aggregationDefersSubscriptionClaimedByPromotion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "promotion-claim",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-promoting",
            displayName: "Promoting Mac",
            routes: [route],
            instanceTag: "promoting-tag",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-promoting",
            macDisplayName: "Promoting Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-promoting",
            client: MobileCoreRPCClient(
                runtime: runtime,
                route: route,
                ticket: ticket,
                allowsStackAuthFallback: true
            ),
            route: route,
            ticket: ticket,
            storedInstanceTag: "promoting-tag",
            authenticatedInstanceTag: "promoting-tag",
            supportedHostCapabilities: ["events.v1"],
            actionCapabilities: .none
        )
        subscription.isTransitioningToFocus = true
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-promoting", instanceTag: "promoting-tag")] = subscription

        await shell.refreshSecondaryMacWorkspaces()

        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-promoting", instanceTag: "promoting-tag")] === subscription)
        #expect(await router.count(of: "workspace.list") == 0)
        subscription.cancel()
    }

    @Test func aggregationKeepsProvisionalDemotionUntilFocusPublishes()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "provisional-demotion",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-provisional",
            displayName: "Provisional Mac",
            routes: [route],
            instanceTag: "provisional-tag",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox()
            ),
            now: { Date() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-provisional",
            macDisplayName: "Provisional Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let focused = MacConnection(
            macDeviceID: "mac-provisional",
            ticket: ticket,
            route: route,
            client: client,
            generation: UUID(),
            displayName: "Provisional Mac",
            instanceTag: "provisional-tag",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        let provisional = SecondaryMacSubscription(
            macDeviceID: "mac-provisional",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "provisional-tag",
            authenticatedInstanceTag: "provisional-tag",
            supportedHostCapabilities: [],
            actionCapabilities: .none,
            displayName: "Provisional Mac"
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        shell.remoteClient = client
        shell.foregroundMacDeviceID = "mac-provisional"
        shell.connections[MacPairingKey(macDeviceID: "mac-provisional", instanceTag: "provisional-tag")] = focused
        #expect(shell.transitionFocusedConnectionToControl(
            provisional,
            replacing: focused
        ))

        await shell.refreshSecondaryMacWorkspaces()

        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-provisional", instanceTag: "provisional-tag")]
            === provisional)
        provisional.detachKeepingClient()
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-provisional", instanceTag: "provisional-tag")] = nil
        await client.disconnect()
    }

    @Test func permanentIdentityMismatchDoesNotSchedulePoolRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "permanent-mismatch",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-permanent",
            displayName: "Permanent Mac",
            routes: [route],
            instanceTag: "expected-tag",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "different-mac",
            instanceTag: "different-tag",
            displayName: "Different Mac"
        )
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: "mac-permanent",
                    tag: "expected-tag",
                    online: true
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        #expect(await router.waitForCount(
            of: "mobile.host.status",
            atLeast: 1
        ))
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-permanent", instanceTag: "expected-tag")] == nil)
        #expect(shell.secondaryAggregationRetryTask == nil)
    }

    @Test func transientTransportFailureStillSchedulesPoolRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "transient-transport",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-transient",
            displayName: "Transient Mac",
            routes: [route],
            instanceTag: "transient-tag",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let attempts = PoolTransportAttemptCounter()
        let runtime = LivenessTestRuntime(
            transportFactory: FailingPoolTransportFactory(
                attempts: attempts
            ),
            now: { Date() }
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: "mac-transient",
                    tag: "transient-tag",
                    online: true
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        #expect(try await pollUntil {
            attempts.count > 0
        })
        #expect(try await pollUntil {
            shell.secondaryAggregationRetryTask != nil
        })
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-transient", instanceTag: "transient-tag")] == nil)
    }

    @Test func identityFreeStatusRunsAuthenticatedRepairBeforeRetrying() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "identity-repair",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-auth",
            displayName: "Auth Mac",
            routes: [route],
            instanceTag: "auth-tag",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "mac-auth",
            instanceTag: "auth-tag",
            displayName: "Auth Mac"
        )
        await router.omitNextHostStatusIdentities()
        let tokenRequests = PoolTransportAttemptCounter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            stackAccessTokenProvider: {
                tokenRequests.increment()
                return "fresh-stack-token"
            },
            now: { Date() }
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: "mac-auth",
                    tag: "auth-tag",
                    online: true
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-auth", instanceTag: "auth-tag")] != nil
        })
        #expect(await router.count(of: "mobile.host.status") == 2)
        #expect(tokenRequests.count > 0)
        #expect(shell.secondaryAggregationRetryTask == nil)
        if let subscription = shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-auth", instanceTag: "auth-tag")] {
            subscription.cancel()
            shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-auth", instanceTag: "auth-tag")] = nil
            await subscription.client.disconnect()
        }
    }

    /// The Tailscale connection method is a strict determinant for every dial,
    /// not just the foreground reconnect. Background multi-Mac aggregation and
    /// broker-discovered secondaries both build their client here, so a stored
    /// Mac whose only routes are Iroh must fail closed instead of opening an
    /// Iroh control session over public paths and managed relays.
    @Test func tailscaleOnlyMethodNeverDialsIrohForSecondaryMac() async throws {
        let iroh = try CmxAttachRoute(
            id: "iroh-secondary",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: []
            ),
            priority: -10_000
        )
        let mac = MobilePairedMac(
            macDeviceID: "iroh-mac",
            displayName: "Iroh Mac",
            routes: [iroh],
            createdAt: .distantPast,
            lastSeenAt: .distantPast,
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            instanceTag: "stable"
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "iroh-mac",
            instanceTag: "stable",
            displayName: "Iroh Mac"
        )
        let factory = KindRecordingTransportFactory(
            router: router,
            box: TransportBox()
        )
        let methodDefaults = UserDefaults(
            suiteName: "tailscale-only-secondary-\(UUID().uuidString)"
        )!
        methodDefaults.set(
            MobileConnectionMethod.tailscale.rawValue,
            forKey: MobileConnectionMethodStore.methodKey
        )
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { fixedNow },
                supportedRouteKinds: [.iroh, .tailscale]
            ),
            isSignedIn: true,
            connectionMethodStore: MobileConnectionMethodStore(
                defaults: methodDefaults
            )
        )

        switch await shell.makeSecondaryClient(for: mac) {
        case .permanentFailure:
            break
        case let .connected(handle):
            Issue.record("Tailscale-only method dialed Iroh for a secondary Mac")
            await handle.client.disconnect()
        case .transientFailure:
            Issue.record("Tailscale-only method left a secondary Iroh dial retrying")
        }
        #expect(factory.attemptedKinds().isEmpty)
    }

    /// Failing closed on ungranted Iroh must not overshoot: a secondary Mac
    /// whose stored Tailscale route carries the device-local grant still
    /// aggregates over that exact route while the Tailscale method is selected.
    @Test func tailscaleOnlySecondaryMacStillConnectsOverAuthorizedRoute()
        async throws {
        let route = try CmxAttachRoute(
            id: "granted-tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.42", port: 56_584)
        )
        let mac = MobilePairedMac(
            macDeviceID: "granted-mac",
            displayName: "Granted Mac",
            routes: [route],
            createdAt: .distantPast,
            lastSeenAt: .distantPast,
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            instanceTag: "stable",
            legacyTailscaleRoutes: [route]
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "granted-mac",
            instanceTag: "stable",
            displayName: "Granted Mac"
        )
        let factory = KindRecordingTransportFactory(
            router: router,
            box: TransportBox()
        )
        let methodDefaults = UserDefaults(
            suiteName: "tailscale-only-granted-\(UUID().uuidString)"
        )!
        methodDefaults.set(
            MobileConnectionMethod.tailscale.rawValue,
            forKey: MobileConnectionMethodStore.methodKey
        )
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { fixedNow },
                supportedRouteKinds: [.iroh, .tailscale]
            ),
            isSignedIn: true,
            connectionMethodStore: MobileConnectionMethodStore(
                defaults: methodDefaults
            )
        )

        switch await shell.makeSecondaryClient(for: mac) {
        case let .connected(handle):
            #expect(handle.storedInstanceTag == "stable")
            await handle.client.disconnect()
        case .transientFailure:
            Issue.record("granted Tailscale secondary failed transiently")
        case .permanentFailure:
            Issue.record("granted Tailscale secondary was refused")
        }
        #expect(factory.attemptedKinds() == [.tailscale])
    }

    @Test func identityFreeLegacyTailscaleStatusUsesValidatedRepair()
        async throws {
        let route = try CmxAttachRoute(
            id: "legacy-identity-repair",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.42", port: 56_584)
        )
        let mac = MobilePairedMac(
            macDeviceID: "legacy-mac",
            displayName: "Legacy Mac",
            routes: [route],
            createdAt: .distantPast,
            lastSeenAt: .distantPast,
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            instanceTag: "legacy-tag",
            legacyTailscaleRoutes: [route]
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "legacy-mac",
            instanceTag: "legacy-tag",
            displayName: "Legacy Mac"
        )
        await router.omitNextHostStatusIdentities()
        let tokenRequests = PoolTransportAttemptCounter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            stackAccessTokenProvider: {
                tokenRequests.increment()
                return "fresh-stack-token"
            },
            now: { Date() },
            supportedRouteKinds: [.tailscale]
        )
        let shell = MobileShellComposite(runtime: runtime, isSignedIn: true)

        switch await shell.makeSecondaryClient(for: mac) {
        case let .connected(handle):
            #expect(handle.storedInstanceTag == "legacy-tag")
            #expect(handle.authenticatedInstanceTag == "legacy-tag")
            await handle.client.disconnect()
        case .transientFailure:
            Issue.record("validated legacy route failed transiently")
        case .permanentFailure:
            Issue.record("validated legacy route skipped authenticated repair")
        }
        #expect(await router.count(of: "mobile.host.status") == 2)
        #expect(tokenRequests.count > 0)
    }

    @Test func controlEventTaskDoesNotRetainShellStore() throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "retain-cycle",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-retain",
            macDisplayName: "Retain Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-retain",
            client: client,
            route: route,
            ticket: ticket,
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        var shell: MobileShellComposite? = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true
        )
        weak let weakShell = shell
        shell?.secondaryMacSubscriptions["mac-retain".pairingKey] = subscription
        shell?.startSecondaryEventConsumer(subscription, displayName: "Retain Mac")

        shell = nil

        #expect(weakShell == nil)
        subscription.cancel()
    }

    @Test func failedTerminalUnsubscribeDisconnectsInsteadOfDemoting() async throws {
        let router = LivenessHostRouter()
        await router.invalidateUnsubscribeRequest(number: 1)
        let closeGate = LivenessTransportCloseGate()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox(),
                closeGate: closeGate
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "unsubscribe-failure",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-a",
            terminalID: "terminal-a",
            macDeviceID: "mac-a",
            macDisplayName: "Mac A",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let connection = MacConnection(
            macDeviceID: "mac-a",
            ticket: ticket,
            route: route,
            client: client,
            generation: UUID(),
            displayName: "Mac A",
            instanceTag: "mmpool",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true
        )
        shell.remoteClient = client
        shell.foregroundMacDeviceID = "mac-a"
        shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")] = connection

        let preparation = Task { @MainActor in
            await shell.prepareFocusedConnectionForHandoff(connection)
        }
        #expect(await closeGate.waitUntilCloseStarted())
        #expect(shell.remoteClient === client)
        do {
            _ = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "mobile.host.status",
                    params: [:]
                )
            )
            Issue.record(
                "discarded foreground accepted a request during teardown"
            )
        } catch {
            // Expected: retirement precedes the suspending transport close.
        }
        await closeGate.release()
        let terminalStopped = await preparation.value
        await shell.commitFocusedConnectionHandoff(
            connection,
            terminalStopped: terminalStopped,
            retainAsControl: true
        )

        #expect(!terminalStopped)
        #expect(shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")] == nil)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")] == nil)
        do {
            _ = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "mobile.host.status",
                    params: [:]
                )
            )
            Issue.record("retired client unexpectedly accepted another request")
        } catch {
            // Expected: a failed unsubscribe retires the old client.
        }
    }

    @Test func pooledClientAdoptionClearsPriorMacCapabilities() throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "pooled-adoption",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let oldTicket = try CmxAttachTicket(
            workspaceID: "workspace-a",
            terminalID: "terminal-a",
            macDeviceID: "mac-a",
            macDisplayName: "Mac A",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let newTicket = try CmxAttachTicket(
            workspaceID: "workspace-b",
            terminalID: "terminal-b",
            macDeviceID: "mac-b",
            macDisplayName: "Mac B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let oldClient = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: oldTicket,
            allowsStackAuthFallback: true
        )
        let newClient = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: newTicket,
            allowsStackAuthFallback: true
        )
        let shell = MobileShellComposite(runtime: runtime, isSignedIn: true)
        shell.remoteClient = oldClient
        shell.supportedHostCapabilities = ["workspace.actions.v1"]
        let stagedGeneration = shell.connectionGeneration

        shell.adoptPooledRemoteClient(newClient)

        #expect(shell.remoteClient === newClient)
        #expect(shell.connectionGeneration != stagedGeneration)
        #expect(!shell.isComposerSubmitIdentityCurrent(
            signIn: shell.signInGeneration,
            connection: shell.connectionGeneration,
            client: oldClient
        ))
        #expect(shell.supportedHostCapabilities.isEmpty)
    }

    @Test func roleSpecificSettersCannotOverwriteOppositeOwner() throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "role-ownership",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "role-owner",
            macDisplayName: "Role Owner",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        func client() -> MobileCoreRPCClient {
            MobileCoreRPCClient(
                runtime: runtime,
                route: route,
                ticket: ticket,
                allowsStackAuthFallback: true
            )
        }
        let focusedClient = client()
        let rejectedControlClient = client()
        let controlClient = client()
        let rejectedFocusedClient = client()
        let shell = MobileShellComposite(runtime: runtime, isSignedIn: true)
        let focused = MacConnection(
            macDeviceID: "mac-focused",
            ticket: ticket,
            route: route,
            client: focusedClient,
            generation: UUID(),
            displayName: "Focused",
            instanceTag: "mmpool",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        let rejectedControl = SecondaryMacSubscription(
            macDeviceID: "mac-focused",
            client: rejectedControlClient,
            route: route,
            ticket: ticket,
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        shell.connections[MacPairingKey(macDeviceID: "mac-focused", instanceTag: "mmpool")] = focused
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-focused", instanceTag: "mmpool")] = rejectedControl

        #expect(shell.connections[MacPairingKey(macDeviceID: "mac-focused", instanceTag: "mmpool")]?.client === focusedClient)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-focused", instanceTag: "mmpool")] == nil)

        let control = SecondaryMacSubscription(
            macDeviceID: "mac-control",
            client: controlClient,
            route: route,
            ticket: ticket,
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        let rejectedFocused = MacConnection(
            macDeviceID: "mac-control",
            ticket: ticket,
            route: route,
            client: rejectedFocusedClient,
            generation: UUID(),
            displayName: "Rejected Focus",
            instanceTag: "mmpool",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-control", instanceTag: "mmpool")] = control
        shell.connections[MacPairingKey(macDeviceID: "mac-control", instanceTag: "mmpool")] = rejectedFocused

        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-control", instanceTag: "mmpool")] === control)
        #expect(shell.connections[MacPairingKey(macDeviceID: "mac-control", instanceTag: "mmpool")] == nil)
        rejectedControl.cancel()
        control.cancel()
    }

    @Test func onePeerSessionCanCarryControlAndFocusedRolesTogether() async throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "multiplexed-role-owner",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-b",
            terminalID: "terminal-b",
            macDeviceID: "mac-b",
            macDisplayName: "Mac B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "pflow",
            authenticatedInstanceTag: "pflow",
            supportedHostCapabilities: ["events.v1"],
            actionCapabilities: .none
        )
        let connection = MacConnection(
            macDeviceID: "mac-b",
            ticket: ticket,
            route: route,
            client: client,
            generation: UUID(),
            displayName: "Mac B",
            instanceTag: "pflow",
            supportedHostCapabilities: ["events.v1"],
            actionCapabilities: .none
        )
        let shell = MobileShellComposite(runtime: runtime, isSignedIn: true)
        let ownerKey = MacPairingKey(
            macDeviceID: "mac-b",
            instanceTag: "pflow"
        )

        shell.secondaryMacSubscriptions[ownerKey] = subscription
        shell.connections[ownerKey] = connection

        #expect(shell.secondaryMacSubscriptions[ownerKey] === subscription)
        #expect(shell.connections[ownerKey]?.client === client)
        #expect(shell.liveMacConnections == [
            MobileMacConnectionSnapshot(
                macDeviceID: "mac-b",
                displayName: "Mac B",
                instanceTag: "pflow",
                role: .focused,
                routeKind: .debugLoopback
            ),
        ])
        subscription.detachKeepingClient()
        // Release the shared loopback port; other tests in this suite dial it.
        await client.disconnect()
    }

    @Test func multiplexedFocusCountsOnceTowardFiveSessionCap() throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let registry = MobileMacConnectionRegistry()

        func peer(
            _ index: Int
        ) throws -> (
            key: MacPairingKey,
            subscription: SecondaryMacSubscription,
            connection: MacConnection
        ) {
            let macDeviceID = "mac-\(index)"
            let route = try CmxAttachRoute(
                id: "peer-\(index)",
                kind: .debugLoopback,
                endpoint: .hostPort(
                    host: "127.0.0.1",
                    port: 57_000 + index
                )
            )
            let ticket = try CmxAttachTicket(
                workspaceID: "workspace-\(index)",
                terminalID: "terminal-\(index)",
                macDeviceID: macDeviceID,
                macDisplayName: macDeviceID,
                routes: [route],
                expiresAt: Date().addingTimeInterval(3_600)
            )
            let client = MobileCoreRPCClient(
                runtime: runtime,
                route: route,
                ticket: ticket,
                allowsStackAuthFallback: true
            )
            return (
                MacPairingKey(
                    macDeviceID: macDeviceID,
                    instanceTag: nil
                ),
                SecondaryMacSubscription(
                    macDeviceID: macDeviceID,
                    client: client,
                    route: route,
                    ticket: ticket,
                    supportedHostCapabilities: [],
                    actionCapabilities: .none
                ),
                MacConnection(
                    macDeviceID: macDeviceID,
                    ticket: ticket,
                    route: route,
                    client: client,
                    generation: UUID(),
                    displayName: macDeviceID,
                    instanceTag: nil,
                    supportedHostCapabilities: [],
                    actionCapabilities: .none
                )
            )
        }

        let focus = try peer(0)
        registry.setControlSubscription(
            focus.subscription,
            for: focus.key
        )
        #expect(registry.transitionToFocusedPreservingControl(
            focus.connection
        ))

        var warmPeers: [(
            key: MacPairingKey,
            subscription: SecondaryMacSubscription,
            connection: MacConnection
        )] = []
        for index in 1 ..< MobileShellComposite.maximumLiveMacConnectionCount {
            let warm = try peer(index)
            warmPeers.append(warm)
            #expect(registry.insertControlIfAbsent(
                warm.subscription,
                maximumControlCount:
                    MobileShellComposite.maximumWarmControlConnectionCount
            ))
        }
        let overflow = try peer(
            MobileShellComposite.maximumLiveMacConnectionCount
        )

        #expect(registry.snapshots.count
            == MobileShellComposite.maximumLiveMacConnectionCount)
        #expect(registry.controlSubscriptions.count
            == MobileShellComposite.maximumLiveMacConnectionCount)
        #expect(!registry.insertControlIfAbsent(
            overflow.subscription,
            maximumControlCount:
                MobileShellComposite.maximumWarmControlConnectionCount
        ))

        #expect(registry.transitionToFocusedPreservingControl(
            warmPeers[0].connection
        ))
        #expect(registry.focusedConnection(for: focus.key) == nil)
        #expect(registry.focusedConnection(for: warmPeers[0].key)?
            .client === warmPeers[0].connection.client)
        #expect(registry.controlSubscription(for: focus.key)?
            .client === focus.subscription.client)
        #expect(registry.controlSubscription(for: warmPeers[0].key)?
            .client === warmPeers[0].subscription.client)
        #expect(registry.snapshots.filter { $0.role == .focused }
            .map(\.macDeviceID) == [warmPeers[0].key.canonicalMacDeviceID])

        registry.setControlSubscription(nil, for: warmPeers[1].key)
        #expect(registry.insertControlIfAbsent(
            overflow.subscription,
            maximumControlCount:
                MobileShellComposite.maximumWarmControlConnectionCount
        ))
        #expect(registry.snapshots.count
            == MobileShellComposite.maximumLiveMacConnectionCount)

        focus.subscription.cancel()
        for warm in warmPeers { warm.subscription.cancel() }
        overflow.subscription.cancel()
    }

    @Test func olderTerminalHandoffCannotClearNewerFence() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_755_000_000)
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { fixedNow }
        )
        let route = try CmxAttachRoute(
            id: "handoff-fence",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 57_100)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-a",
            terminalID: "terminal-a",
            macDeviceID: "mac-a",
            macDisplayName: "Mac A",
            routes: [route],
            expiresAt: fixedNow.addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let shell = MobileShellComposite(runtime: runtime, isSignedIn: true)
        shell.remoteClient = client
        let older = try #require(
            shell.beginTerminalSubscriptionHandoff(on: client)
        )
        let newer = try #require(
            shell.beginTerminalSubscriptionHandoff(on: client)
        )

        shell.finishTerminalSubscriptionHandoff(older)
        // Isolate the fence token: the older handoff's release must be a no-op
        // while the newer fence still owns the client.
        #expect(
            shell.terminalSubscriptionHandoffFences[ObjectIdentifier(client)]?
                .fenceID == newer.fenceID
        )
        shell.startTerminalRefreshPolling()
        #expect(shell.terminalEventListenerTask == nil)

        shell.finishTerminalSubscriptionHandoff(newer)
        #expect(
            shell.terminalSubscriptionHandoffFences[ObjectIdentifier(client)]
                == nil
        )
        shell.startTerminalRefreshPolling()
        #expect(shell.terminalEventListenerTask != nil)
        shell.stopTerminalRefreshPolling()
        await client.disconnect()
    }

    @Test func focusedControlFailurePreservesSharedPeerSession() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_755_000_000)
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { fixedNow }
        )
        let route = try CmxAttachRoute(
            id: "focused-control-failure",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 57_101)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-a",
            terminalID: "terminal-a",
            macDeviceID: "mac-a",
            macDisplayName: "Mac A",
            routes: [route],
            expiresAt: fixedNow.addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-a",
            client: client,
            route: route,
            ticket: ticket,
            supportedHostCapabilities: ["events.v1"],
            actionCapabilities: .none
        )
        let connection = MacConnection(
            macDeviceID: "mac-a",
            ticket: ticket,
            route: route,
            client: client,
            generation: UUID(),
            displayName: "Mac A",
            instanceTag: nil,
            supportedHostCapabilities: ["events.v1"],
            actionCapabilities: .none
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected
        )
        shell.remoteClient = client
        shell.foregroundMacDeviceID = "mac-a"
        shell.secondaryMacSubscriptions[connection.ownerKey] = subscription
        #expect(shell.installFocusedConnectionPreservingControl(connection))

        await shell.retireSecondaryControlOwner(
            subscription,
            shouldRetry: true
        )

        #expect(shell.remoteClient === client)
        #expect(shell.connections[connection.ownerKey]?.client === client)
        #expect(shell.secondaryMacSubscriptions[connection.ownerKey] == nil)
        #expect(shell.liveMacConnections == [
            MobileMacConnectionSnapshot(
                macDeviceID: "mac-a",
                displayName: "Mac A",
                instanceTag: nil,
                role: .focused,
                routeKind: .debugLoopback
            ),
        ])
        #expect(shell.secondaryMacDrainReservation(
            for: connection.ownerKey
        ) == nil)
        await client.disconnect()
    }

    @Test func staleGenerationCannotDemoteOrInvalidateReusedFocusedClient() async throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "generation-owner",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-a",
            terminalID: "terminal-a",
            macDeviceID: "mac-a",
            macDisplayName: "Mac A",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let stale = MacConnection(
            macDeviceID: "mac-a",
            ticket: ticket,
            route: route,
            client: client,
            generation: UUID(),
            displayName: "Mac A",
            instanceTag: "mmpool",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        let currentGeneration = UUID()
        let current = MacConnection(
            macDeviceID: "mac-a",
            ticket: ticket,
            route: route,
            client: client,
            generation: currentGeneration,
            displayName: "Mac A",
            instanceTag: "mmpool",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected
        )
        shell.connectionGeneration = currentGeneration
        shell.remoteClient = client
        shell.foregroundMacDeviceID = "mac-a"
        shell.activeTicket = ticket
        shell.activeRoute = route
        shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")] = current

        await shell.installControlConnection(from: stale)
        shell.invalidateFocusedConnectionAfterAbortedHandoff(stale)

        #expect(shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")]?.generation == currentGeneration)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")] == nil)
        #expect(shell.remoteClient === client)
        #expect(shell.foregroundMacDeviceID == "mac-a")
        let response = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.host.status",
                params: [:]
            )
        )
        #expect(!response.isEmpty)

        shell.connectionGeneration = currentGeneration
        shell.invalidateFocusedConnectionAfterAbortedHandoff(current)

        #expect(shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")] == nil)
        #expect(shell.remoteClient == nil)
        #expect(shell.foregroundMacDeviceID == nil)
        #expect(shell.connectionState == .disconnected)
        await client.disconnect()
    }

    @Test func demotedLegacyMacUsesRefreshOnlyControlMaintenance() async throws {
        let clock = ControlPoolManualClock()
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "legacy-demotion",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-a",
            terminalID: "terminal-a",
            macDeviceID: "mac-a",
            macDisplayName: "Mac A",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let generation = UUID()
        let connection = MacConnection(
            macDeviceID: "mac-a",
            ticket: ticket,
            route: route,
            client: client,
            generation: generation,
            displayName: "Mac A",
            instanceTag: "legacy",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            controlPlaneSchedulingClock: clock
        )
        shell.connectionGeneration = generation
        shell.remoteClient = client
        shell.foregroundMacDeviceID = "mac-a"
        shell.activeTicket = ticket
        shell.activeRoute = route
        shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "legacy")] = connection

        await shell.installControlConnection(from: connection)

        #expect(shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "legacy")] == nil)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-a", instanceTag: "legacy")]?.client === client)
        #expect(try await pollUntil { clock.sleeperCount == 1 })
        #expect(await router.count(of: "mobile.events.subscribe") == 0)

        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-a", instanceTag: "legacy")]?.detachKeepingClient()
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-a", instanceTag: "legacy")] = nil
        await client.disconnect()
    }

    @Test func cancelledPreparedHandoffRemainsRepairableAcrossNewGeneration() async throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "cancelled-prepared-handoff",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-a",
            terminalID: "terminal-a",
            macDeviceID: "mac-a",
            macDisplayName: "Mac A",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let focusedGeneration = UUID()
        let connection = MacConnection(
            macDeviceID: "mac-a",
            ticket: ticket,
            route: route,
            client: client,
            generation: focusedGeneration,
            displayName: "Mac A",
            instanceTag: "mmpool",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected
        )
        shell.connectionGeneration = focusedGeneration
        shell.remoteClient = client
        shell.foregroundMacDeviceID = "mac-a"
        shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")] = connection

        #expect(await shell.prepareFocusedConnectionForHandoff(connection))
        #expect(shell.focusedHandoffPreparedGenerations.contains(
            focusedGeneration
        ))

        let restoreGeneration = UUID()
        shell.connectionGeneration = restoreGeneration
        shell.invalidateFocusedConnectionAfterAbortedHandoff(connection)

        #expect(shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")]?.generation == focusedGeneration)
        #expect(shell.remoteClient === client)
        #expect(shell.connectionState == .connected)
        #expect(shell.focusedHandoffPreparedGenerations.contains(
            focusedGeneration
        ))

        shell.installFocusedConnection(MacConnection(
            macDeviceID: "mac-a",
            ticket: ticket,
            route: route,
            client: client,
            generation: restoreGeneration,
            displayName: "Mac A",
            instanceTag: "mmpool",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        ))
        #expect(shell.focusedHandoffPreparedGenerations.isEmpty)
        await client.disconnect()
    }

    @Test func focusedHandoffDrainsSubscribeBeforeFinalUnsubscribe()
        async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let shell = try await makeConnectedStore(
            router: router,
            box: box,
            clock: TestClock(),
            probeTimeoutNanoseconds: 1_000_000_000
        )
        let macDeviceID = try #require(shell.foregroundMacDeviceID)
        let connection = try #require(shell.connections[macDeviceID])
        let initialSubscribeCount =
            await router.count(of: "mobile.events.subscribe")
        await router.delaySubscribeRequest(
            number: initialSubscribeCount + 1
        )
        shell.resyncTerminalOutput(
            reason: "handoff_drain_test",
            restartEventStream: false
        )
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: initialSubscribeCount + 1
        ))
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })

        let handoff = Task { @MainActor in
            await shell.prepareFocusedConnectionForHandoff(connection)
        }
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(await router.count(of: "mobile.events.unsubscribe") == 0)

        await router.releaseNextHeld()
        #expect(await router.waitForCount(
            of: "mobile.events.unsubscribe",
            atLeast: 1
        ))
        #expect(await handoff.value)
        await connection.client.disconnect()
    }

    @Test func malformedControlSubscribeAckTearsDownFalseReadyState() async throws {
        let router = LivenessHostRouter()
        await router.invalidateSubscribeRequest(number: 1)
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "invalid-control-ack",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-invalid",
            macDisplayName: "Invalid Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let shell = MobileShellComposite(runtime: runtime, isSignedIn: true)
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-invalid",
            client: client,
            route: route,
            ticket: ticket,
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        shell.workspacesByMac["mac-invalid".pairingKey] = MacWorkspaceState(
            macDeviceID: "mac-invalid",
            displayName: "Invalid Mac",
            workspaces: [],
            status: .connected
        )
        shell.secondaryMacSubscriptions["mac-invalid".pairingKey] = subscription

        shell.startSecondaryEventConsumer(
            subscription,
            displayName: "Invalid Mac"
        )

        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions["mac-invalid".pairingKey] == nil
        })
        #expect(shell.workspacesByMac["mac-invalid".pairingKey]?.status == .unavailable)
        #expect(!shell.liveMacConnections.contains {
            $0.macDeviceID == "mac-invalid"
        })
        await client.disconnect()
    }

    @Test func promotionFenceDrainsInFlightKeepaliveReassertion() async throws {
        let clock = ControlPoolManualClock()
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "promotion-keepalive",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-b",
            macDisplayName: "Mac B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            controlPlaneSchedulingClock: clock
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            supportedHostCapabilities: ["events.v1"],
            actionCapabilities: .none
        )
        shell.secondaryMacSubscriptions["mac-b".pairingKey] = subscription
        shell.startSecondaryEventConsumer(subscription, displayName: "Mac B")
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))
        #expect(try await pollUntil { clock.sleeperCount == 1 })
        await router.holdSubscribeRequest(number: 2)
        clock.advance(by: .seconds(20))
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 2
        ))

        let completion = PromotionFenceCompletion()
        let fence = Task { @MainActor in
            let result = await shell.prepareSecondarySubscriptionForPromotion(
                subscription
            )
            await completion.finish()
            return result
        }
        for _ in 0 ..< 4 { await Task.yield() }
        #expect(!(await completion.isFinished))
        #expect(subscription.isTransitioningToFocus)
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })

        await router.releaseAllHeld()
        #expect(await fence.value)
        #expect(await completion.isFinished)
        #expect(await shell.unsubscribeEventStream(
            on: client,
            streamID: subscription.streamID
        ))
        #expect(await router.count(of: "mobile.events.subscribe") == 2)

        subscription.detachKeepingClient()
        shell.secondaryMacSubscriptions["mac-b".pairingKey] = nil
        await client.disconnect()
    }

    @Test func promotionDoesNotAwaitAnotherMacsKeepalive() async throws {
        let clock = ControlPoolManualClock()
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "unrelated-promotion-keepalive",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        func subscription(_ macDeviceID: String) throws
            -> SecondaryMacSubscription {
            let ticket = try CmxAttachTicket(
                workspaceID: "",
                terminalID: nil,
                macDeviceID: macDeviceID,
                macDisplayName: macDeviceID,
                routes: [route],
                expiresAt: Date().addingTimeInterval(3_600)
            )
            return SecondaryMacSubscription(
                macDeviceID: macDeviceID,
                client: MobileCoreRPCClient(
                    runtime: runtime,
                    route: route,
                    ticket: ticket,
                    allowsStackAuthFallback: true
                ),
                route: route,
                ticket: ticket,
                supportedHostCapabilities: ["events.v1"],
                actionCapabilities: .none
            )
        }
        let first = try subscription("mac-a")
        let second = try subscription("mac-b")
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            controlPlaneSchedulingClock: clock
        )
        shell.secondaryMacSubscriptions["mac-a".pairingKey] = first
        shell.startSecondaryEventConsumer(first, displayName: "Mac A")
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))
        shell.secondaryMacSubscriptions["mac-b".pairingKey] = second
        shell.startSecondaryEventConsumer(second, displayName: "Mac B")
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 2
        ))
        #expect(try await pollUntil {
            first.hasActivatedControlStream
                && second.hasActivatedControlStream
                && clock.sleeperCount == 1
        })

        await router.holdSubscribeRequest(number: 3)
        clock.advance(by: .seconds(20))
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 3
        ))
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })
        let subscribeStreamIDs = await router.streamIDs(
            for: "mobile.events.subscribe"
        )
        let heldStreamID = try #require(
            subscribeStreamIDs.compactMap { $0 }.last
        )
        let target = heldStreamID == first.streamID ? second : first
        let targetMacID = target.macDeviceID
        let completion = PromotionFenceCompletion()
        let fence = Task { @MainActor in
            let result = await shell.prepareSecondarySubscriptionForPromotion(
                target
            )
            await completion.finish()
            return result
        }

        #expect(try await pollUntil {
            await completion.isFinished
        })
        await router.releaseAllHeld()
        #expect(await fence.value)

        first.detachKeepingClient()
        second.detachKeepingClient()
        shell.secondaryMacSubscriptions["mac-a".pairingKey] = nil
        shell.secondaryMacSubscriptions["mac-b".pairingKey] = nil
        await first.client.disconnect()
        await second.client.disconnect()
    }

    @Test func recreatedControlRegistrationCatchesUpAggregateState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "control-gap",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Mac B",
            routes: [route],
            instanceTag: "mmpool",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let clock = ControlPoolManualClock()
        let router = LivenessHostRouter()
        await router.scriptWorkspaceListTitles([
            "Initial Catch-up",
            "Stale Recreated Catch-up",
            "Event Fresh Catch-up",
            "Failed Catch-up",
        ])
        let transportBox = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: transportBox
            ),
            now: { Date() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-b",
            macDisplayName: "Mac B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "mmpool",
            authenticatedInstanceTag: "mmpool",
            supportedHostCapabilities: [
                "events.v1",
                "notification.feed.v1",
            ],
            actionCapabilities: .none,
            displayName: "Mac B"
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" },
            controlPlaneSchedulingClock: clock
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] = subscription
        shell.startSecondaryEventConsumer(subscription, displayName: "Mac B")

        #expect(try await pollUntil {
            let feedFetchCount = await router.count(
                of: "notification.feed.list"
            )
            return subscription.hasActivatedControlStream
                && shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")]?.workspaces.first?.name
                    == "Initial Catch-up"
                && feedFetchCount >= 1
                && clock.sleeperCount == 1
        })
        let feedFetchesBeforeGap = await router.count(
            of: "notification.feed.list"
        )

        await router.holdWorkspaceListRequest(number: 2)
        await router.failWorkspaceListRequest(number: 2)
        await router.scriptNotificationFeedRevisions([2, 3])
        shell.notificationFeedKnownRevisionsByMac["mac-b\u{1F}mmpool"] = 3
        await router.dropSubscription()
        clock.advance(by: .seconds(20))

        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 2
        ))
        #expect(await router.waitForCount(
            of: "workspace.list",
            atLeast: 2
        ))
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })
        let transport = try #require(transportBox.get())
        await transport.deliver(
            try controlPoolWorkspaceUpdatedEventFrame()
        )
        for _ in 0 ..< 8 { await Task.yield() }
        #expect(await router.count(of: "workspace.list") == 2)
        await router.releaseAllHeld()
        #expect(await router.waitForCount(
            of: "workspace.list",
            atLeast: 3
        ))
        #expect(try await pollUntil {
            let feedFetchCount = await router.count(
                of: "notification.feed.list"
            )
            return shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")]?.workspaces.first?.name
                == "Event Fresh Catch-up"
                && feedFetchCount >= feedFetchesBeforeGap + 2
                && clock.sleeperCount == 1
        })
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] === subscription)

        await router.failNextNotificationFeedLists()
        await router.dropSubscription()
        clock.advance(by: .seconds(20))

        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 3
        ))
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] == nil
        })
        #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")]?.status == .unavailable)
        await client.disconnect()
    }

    @Test
    func notificationFeedRefreshStopsAfterOneTrailingStaleSnapshot()
        async throws {
        let clock = ControlPoolManualClock()
        let route = try CmxAttachRoute(
            id: "bounded-notification-refresh",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_588)
        )
        let router = LivenessHostRouter()
        await router.scriptNotificationFeedRevisions([2, 2, 2, 2])
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-b",
            macDisplayName: "Mac B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "mmpool",
            authenticatedInstanceTag: "mmpool",
            supportedHostCapabilities: ["notification.feed.v1"],
            actionCapabilities: .none,
            displayName: "Mac B"
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            controlPlaneSchedulingClock: clock
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] = subscription
        shell.notificationFeedKnownRevisionsByMac["mac-b\u{1F}mmpool"] = 3

        shell.scheduleSecondaryNotificationFeedRefresh(
            macDeviceID: "mac-b\u{1F}mmpool",
            client: client,
            displayName: "Mac B"
        )

        #expect(await router.waitForCount(
            of: "notification.feed.list",
            atLeast: 2
        ))
        #expect(try await pollUntil {
            shell.notificationFeedRefreshTasksByMac["mac-b\u{1F}mmpool"] == nil
                && shell.notificationFeedRefreshRetryTasksByMac["mac-b\u{1F}mmpool"]
                    != nil
                && clock.sleeperCount == 1
        })
        shell.notificationFeedKnownRevisionsByMac["mac-b\u{1F}mmpool"] = 4
        shell.scheduleSecondaryNotificationFeedRefresh(
            macDeviceID: "mac-b\u{1F}mmpool",
            client: client,
            displayName: "Mac B"
        )
        for _ in 0 ..< 8 { await Task.yield() }
        #expect(await router.count(of: "notification.feed.list") == 2)
        #expect(clock.sleeperCount == 1)

        clock.advance(by: .seconds(1))
        #expect(await router.waitForCount(
            of: "notification.feed.list",
            atLeast: 4
        ))
        #expect(try await pollUntil {
            shell.notificationFeedRefreshTasksByMac["mac-b\u{1F}mmpool"] == nil
                && shell.notificationFeedRefreshRetryTasksByMac["mac-b\u{1F}mmpool"]
                    == nil
        })
        clock.advance(by: .seconds(10))
        for _ in 0 ..< 8 { await Task.yield() }
        #expect(await router.count(of: "notification.feed.list") == 4)
        #expect(shell.notificationFeedRefreshPendingMacIDs.contains("mac-b\u{1F}mmpool"))
        #expect(shell.notificationFeedSnapshotsByMac["mac-b\u{1F}mmpool"] == nil)

        shell.removeNotificationFeedSnapshot(macDeviceID: "mac-b")
        subscription.detachKeepingClient()
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] = nil
        await client.disconnect()
    }

    @Test
    func controlGapActivationDoesNotAwaitTrailingNotificationCoalescer()
        async throws {
        let route = try CmxAttachRoute(
            id: "bounded-notification-catch-up",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_587)
        )
        let router = LivenessHostRouter()
        await router.scriptNotificationFeedRevisions([2, 3, 4])
        await router.holdNotificationFeedListRequest(number: 2)
        await router.holdNotificationFeedListRequest(number: 3)
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-b",
            macDisplayName: "Mac B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "mmpool",
            authenticatedInstanceTag: "mmpool",
            supportedHostCapabilities: ["notification.feed.v1"],
            actionCapabilities: .none,
            displayName: "Mac B"
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] = subscription
        shell.notificationFeedKnownRevisionsByMac["mac-b\u{1F}mmpool"] = 3
        let completion = PromotionFenceCompletion()
        let repair = Task { @MainActor in
            let result =
                await shell.reconcileSecondaryNotificationFeedAfterControlGap(
                    macDeviceID: "mac-b\u{1F}mmpool",
                    client: client,
                    displayName: "Mac B"
                )
            await completion.finish()
            return result
        }

        #expect(await router.waitForCount(
            of: "notification.feed.list",
            atLeast: 2
        ))
        shell.notificationFeedKnownRevisionsByMac["mac-b\u{1F}mmpool"] = 4
        await router.releaseNextHeld()
        #expect(await router.waitForCount(
            of: "notification.feed.list",
            atLeast: 3
        ))
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })
        #expect(try await pollUntil {
            await completion.isFinished
        })

        await router.releaseAllHeld()
        #expect(await repair.value)
        subscription.detachKeepingClient()
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] = nil
        await client.disconnect()
    }

    @Test func workspaceEventChurnPublishesLeadingAndBoundedTrailingSnapshots()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "bounded-workspace-churn",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Mac B",
            routes: [route],
            instanceTag: "mmpool",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let router = LivenessHostRouter()
        await router.scriptWorkspaceListTitles([
            "Initial Snapshot",
            "Leading Snapshot",
            "Trailing Snapshot",
            "Deferred Fresh Snapshot",
        ])
        await router.holdWorkspaceListRequest(number: 2)
        await router.holdWorkspaceListRequest(number: 3)
        let transportBox = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: transportBox
            ),
            now: { Date() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-b",
            macDisplayName: "Mac B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "mmpool",
            authenticatedInstanceTag: "mmpool",
            supportedHostCapabilities: [
                "events.v1",
                "notification.feed.v1",
            ],
            actionCapabilities: .none,
            displayName: "Mac B"
        )
        let clock = ControlPoolManualClock()
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" },
            controlPlaneSchedulingClock: clock
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] = subscription
        shell.startSecondaryEventConsumer(subscription, displayName: "Mac B")
        #expect(try await pollUntil {
            subscription.hasActivatedControlStream
                && shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")]?.workspaces.first?.name
                    == "Initial Snapshot"
        })
        let transport = try #require(transportBox.get())

        await transport.deliver(
            try controlPoolWorkspaceUpdatedEventFrame()
        )
        #expect(await router.waitForCount(of: "workspace.list", atLeast: 2))
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })
        for _ in 0 ..< 8 {
            await transport.deliver(
                try controlPoolWorkspaceUpdatedEventFrame()
            )
        }
        await router.releaseNextHeld()

        #expect(await router.waitForCount(of: "workspace.list", atLeast: 3))
        #expect(try await pollUntil {
            let hasLeadingSnapshot =
                shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")]?.workspaces.first?.name
                == "Leading Snapshot"
            let heldRequestCount = await router.heldRequestCount()
            return hasLeadingSnapshot && heldRequestCount == 1
        })
        for _ in 0 ..< 8 {
            await transport.deliver(
                try controlPoolWorkspaceUpdatedEventFrame()
            )
        }
        await router.releaseNextHeld()

        #expect(try await pollUntil {
            shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")]?.workspaces.first?.name
                == "Trailing Snapshot"
        })
        #expect(try await pollUntil {
            subscription.deferredRefreshTask != nil
        })
        subscription.isTransitioningToFocus = true
        clock.advance(by: .milliseconds(500))
        for _ in 0 ..< 16 { await Task.yield() }
        #expect(await router.count(of: "workspace.list") == 3)
        #expect(subscription.deferredRefreshTask == nil)
        #expect(subscription.refreshPending)
        let feedFetchesBeforeResume = await router.count(
            of: "notification.feed.list"
        )

        await shell.resumeSecondarySubscriptionAfterAbortedPromotion(
            subscription
        )
        #expect(await router.waitForCount(
            of: "notification.feed.list",
            atLeast: feedFetchesBeforeResume + 1
        ))
        #expect(try await pollUntil {
            subscription.deferredRefreshTask != nil
        })
        for _ in 0 ..< 16 { await Task.yield() }
        clock.advance(by: .milliseconds(500))
        #expect(await router.waitForCount(of: "workspace.list", atLeast: 4))
        #expect(try await pollUntil {
            shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")]?.workspaces.first?.name
                == "Deferred Fresh Snapshot"
        })
        #expect(await router.count(of: "workspace.list") == 4)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] === subscription)

        subscription.detachKeepingClient()
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] = nil
        await client.disconnect()
    }

    @Test func permanentControlSubscriptionFailureDoesNotRetry() async throws {
        let clock = ControlPoolManualClock()
        let router = LivenessHostRouter()
        await router.failSubscribeRequest(
            number: 1,
            code: "method_not_found"
        )
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "unsupported-control-events",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-b",
            macDisplayName: "Mac B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            supportedHostCapabilities: ["events.v1"],
            actionCapabilities: .none
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            presence: IdlePresence(),
            controlPlaneSchedulingClock: clock
        )
        shell.secondaryMacSubscriptions["mac-b".pairingKey] = subscription
        shell.startSecondaryEventConsumer(subscription, displayName: "Mac B")

        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions["mac-b".pairingKey] == nil
        })
        #expect(shell.workspacesByMac["mac-b".pairingKey]?.status != .connected)
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(60))
        for _ in 0 ..< 16 { await Task.yield() }
        #expect(await router.count(of: "mobile.events.subscribe") == 1)
        await client.disconnect()
    }

    @Test func promotionFenceDrainsInitialControlActivation() async throws {
        let router = LivenessHostRouter()
        await router.holdSubscribeRequest(number: 1)
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "initial-promotion-fence",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-b",
            macDisplayName: "Mac B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let shell = MobileShellComposite(runtime: runtime, isSignedIn: true)
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            supportedHostCapabilities: ["events.v1"],
            actionCapabilities: .none
        )
        shell.secondaryMacSubscriptions["mac-b".pairingKey] = subscription
        shell.startSecondaryEventConsumer(subscription, displayName: "Mac B")
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })

        let completion = PromotionFenceCompletion()
        let fence = Task { @MainActor in
            let result = await shell.prepareSecondarySubscriptionForPromotion(
                subscription
            )
            await completion.finish()
            return result
        }
        for _ in 0 ..< 4 { await Task.yield() }
        #expect(!(await completion.isFinished))
        #expect(subscription.isTransitioningToFocus)

        await router.releaseAllHeld()
        #expect(await fence.value)
        #expect(await shell.unsubscribeEventStream(
            on: client,
            streamID: subscription.streamID
        ))
        #expect(await router.count(of: "mobile.events.subscribe") == 1)

        subscription.detachKeepingClient()
        shell.secondaryMacSubscriptions["mac-b".pairingKey] = nil
        await client.disconnect()
    }

    @Test func promotionFenceTimesOutBlockedControlReassertion() async throws {
        let router = LivenessHostRouter()
        await router.holdSubscribeRequest(number: 1)
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() },
            livenessProbeTimeoutNanoseconds: 1_000_000_000
        )
        let route = try CmxAttachRoute(
            id: "bounded-promotion-reassertion",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-b",
            macDisplayName: "Mac B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "mmpool",
            authenticatedInstanceTag: "mmpool",
            supportedHostCapabilities: ["events.v1"],
            actionCapabilities: .none,
            displayName: "Mac B"
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionHandoffDrainTimeoutNanoseconds: 20_000_000
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] = subscription
        shell.startSecondaryEventConsumer(
            subscription,
            displayName: "Mac B"
        )
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })

        #expect(!(await shell.prepareSecondarySubscriptionForPromotion(
            subscription
        )))
        #expect(subscription.isTransitioningToFocus)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] == nil)
        #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")]?.status != .connected)

        await router.releaseAllHeld()
        await client.disconnect()
    }

    @Test func keepaliveSkipsAnotherMacsInitialActivation() async throws {
        let clock = ControlPoolManualClock()
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "single-flight-activation",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        func subscription(_ macDeviceID: String) throws
            -> SecondaryMacSubscription {
            let ticket = try CmxAttachTicket(
                workspaceID: "",
                terminalID: nil,
                macDeviceID: macDeviceID,
                macDisplayName: macDeviceID,
                routes: [route],
                expiresAt: Date().addingTimeInterval(3_600)
            )
            return SecondaryMacSubscription(
                macDeviceID: macDeviceID,
                client: MobileCoreRPCClient(
                    runtime: runtime,
                    route: route,
                    ticket: ticket,
                    allowsStackAuthFallback: true
                ),
                route: route,
                ticket: ticket,
                supportedHostCapabilities: ["events.v1"],
                actionCapabilities: .none
            )
        }
        let first = try subscription("mac-a")
        let second = try subscription("mac-b")
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            controlPlaneSchedulingClock: clock
        )
        shell.secondaryMacSubscriptions["mac-a".pairingKey] = first
        shell.startSecondaryEventConsumer(first, displayName: "Mac A")
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))
        #expect(try await pollUntil {
            first.hasActivatedControlStream && clock.sleeperCount == 1
        })

        await router.holdSubscribeRequest(number: 2)
        shell.secondaryMacSubscriptions["mac-b".pairingKey] = second
        shell.startSecondaryEventConsumer(second, displayName: "Mac B")
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 2
        ))
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })

        clock.advance(by: .seconds(20))
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 3
        ))
        #expect(!second.hasActivatedControlStream)
        #expect(await router.count(of: "mobile.events.subscribe") == 3)

        await router.releaseAllHeld()
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions["mac-b".pairingKey] == nil
        })
        #expect(await router.count(of: "mobile.events.subscribe") == 3)

        first.detachKeepingClient()
        second.detachKeepingClient()
        shell.secondaryMacSubscriptions["mac-a".pairingKey] = nil
        shell.secondaryMacSubscriptions["mac-b".pairingKey] = nil
        await first.client.disconnect()
        await second.client.disconnect()
    }

    @Test func stalledKeepaliveDoesNotDelayAnotherMac() async throws {
        let clock = ControlPoolManualClock()
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "concurrent-keepalive",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        func subscription(_ macDeviceID: String) throws
            -> SecondaryMacSubscription {
            let ticket = try CmxAttachTicket(
                workspaceID: "",
                terminalID: nil,
                macDeviceID: macDeviceID,
                macDisplayName: macDeviceID,
                routes: [route],
                expiresAt: Date().addingTimeInterval(3_600)
            )
            return SecondaryMacSubscription(
                macDeviceID: macDeviceID,
                client: MobileCoreRPCClient(
                    runtime: runtime,
                    route: route,
                    ticket: ticket,
                    allowsStackAuthFallback: true
                ),
                route: route,
                ticket: ticket,
                supportedHostCapabilities: ["events.v1"],
                actionCapabilities: .none
            )
        }
        let first = try subscription("mac-a")
        let second = try subscription("mac-b")
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            controlPlaneSchedulingClock: clock
        )
        shell.secondaryMacSubscriptions["mac-a".pairingKey] = first
        shell.startSecondaryEventConsumer(first, displayName: "Mac A")
        shell.secondaryMacSubscriptions["mac-b".pairingKey] = second
        shell.startSecondaryEventConsumer(second, displayName: "Mac B")
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 2
        ))
        #expect(try await pollUntil {
            first.hasActivatedControlStream
                && second.hasActivatedControlStream
                && clock.sleeperCount == 1
        })

        await router.holdSubscribeRequest(number: 3)
        clock.advance(by: .seconds(20))

        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 4,
            timeoutNanoseconds: 500_000_000
        ))
        #expect(try await pollUntil {
            await router.heldRequestCount() == 1
        })

        await router.releaseAllHeld()
        first.detachKeepingClient()
        second.detachKeepingClient()
        shell.secondaryMacSubscriptions["mac-a".pairingKey] = nil
        shell.secondaryMacSubscriptions["mac-b".pairingKey] = nil
        await first.client.disconnect()
        await second.client.disconnect()
    }

    @Test func freshSwitchStagesMetadataAndReplacesTargetControlOwner() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "mac-b",
            instanceTag: "mmpool",
            displayName: "Mac B"
        )
        let targetCapabilities = [
            "events.v1",
            "workspace.actions.v1",
            "workspace.close.v1",
        ]
        await router.setCapabilities(targetCapabilities)
        await router.holdWorkspaceListRequest(number: 1)
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let oldRoute = try CmxAttachRoute(
            id: "staged-old",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_583)
        )
        let targetRoute = try CmxAttachRoute(
            id: "staged-target",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let oldTicket = try CmxAttachTicket(
            workspaceID: "workspace-a",
            terminalID: "terminal-a",
            macDeviceID: "mac-a",
            macDisplayName: "Mac A",
            routes: [oldRoute],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [oldRoute],
            instanceTag: "mmpool",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let targetTicket = try CmxAttachTicket(
            workspaceID: "workspace-b",
            terminalID: "terminal-b",
            macDeviceID: "mac-b",
            macDisplayName: "Target Placeholder",
            routes: [targetRoute],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let oldClient = MobileCoreRPCClient(
            runtime: runtime,
            route: oldRoute,
            ticket: oldTicket,
            allowsStackAuthFallback: true
        )
        let displacedControlClient = MobileCoreRPCClient(
            runtime: runtime,
            route: targetRoute,
            ticket: targetTicket,
            allowsStackAuthFallback: true
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        shell.remoteClient = oldClient
        shell.foregroundMacDeviceID = "mac-a"
        shell.activeTicket = oldTicket
        shell.activeRoute = oldRoute
        shell.connectedHostName = "Mac A"
        shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")] = MacConnection(
            macDeviceID: "mac-a",
            ticket: oldTicket,
            route: oldRoute,
            client: oldClient,
            generation: UUID(),
            displayName: "Mac A",
            instanceTag: "mmpool",
            supportedHostCapabilities: ["old.capability"],
            actionCapabilities: .none
        )
        shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")] = MacWorkspaceState(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            workspaces: [
                MobileWorkspacePreview(
                    id: .init(rawValue: "workspace-a"),
                    macDeviceID: "mac-a",
                    name: "Workspace A",
                    terminals: []
                ),
            ],
            status: .connected
        )
        shell.setSelectedWorkspaceID(
            shell.workspaces.first(where: { $0.macDeviceID == "mac-a" })?.id
        )
        let displacedControl = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: displacedControlClient,
            route: targetRoute,
            ticket: targetTicket,
            storedInstanceTag: "mmpool",
            authenticatedInstanceTag: "mmpool",
            supportedHostCapabilities: ["old.control.capability"],
            actionCapabilities: .none,
            displayName: "Mac B"
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] = displacedControl
        for index in 0 ..<
            MobileShellComposite.maximumWarmControlConnectionCount - 1 {
            let macDeviceID = "mac-fill-\(index)"
            let fillerRoute = try CmxAttachRoute(
                id: "staged-fill-\(index)",
                kind: .debugLoopback,
                endpoint: .hostPort(
                    host: "127.0.0.1",
                    port: 56_600 + index
                )
            )
            let fillerTicket = try CmxAttachTicket(
                workspaceID: "",
                terminalID: nil,
                macDeviceID: macDeviceID,
                macDisplayName: macDeviceID,
                routes: [fillerRoute],
                expiresAt: Date().addingTimeInterval(3_600)
            )
            shell.secondaryMacSubscriptions[macDeviceID.pairingKey] =
                SecondaryMacSubscription(
                    macDeviceID: macDeviceID,
                    client: MobileCoreRPCClient(
                        runtime: runtime,
                        route: fillerRoute,
                        ticket: fillerTicket,
                        allowsStackAuthFallback: true
                    ),
                    route: fillerRoute,
                    ticket: fillerTicket,
                    storedInstanceTag: "mmpool",
                    authenticatedInstanceTag: "mmpool",
                    supportedHostCapabilities: [],
                    actionCapabilities: .none
                )
        }
        #expect(shell.secondaryMacSubscriptions.count
            == MobileShellComposite.maximumWarmControlConnectionCount)
        shell.startSecondaryEventConsumer(
            displacedControl,
            displayName: "Mac B"
        )
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))

        let connectTask = Task { @MainActor in
            try await shell.connect(
                ticket: targetTicket,
                allowsStackAuthFallback: true,
                pairedMacDeviceID: "mac-b",
                instanceTagExpectation: .require("mmpool")
            )
        }
        _ = await router.waitForCount(of: "workspace.list", atLeast: 1)

        #expect(shell.remoteClient === oldClient)
        #expect(shell.activeTicket?.macDeviceID == "mac-a")
        #expect(shell.activeRoute == oldRoute)
        #expect(shell.connectedHostName == "Mac A")
        #expect(displacedControl.isTransitioningToFocus)
        do {
            _ = try await displacedControlClient.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "mobile.host.status",
                    params: [:]
                )
            )
            Issue.record(
                "target control owner stayed usable during the fresh target RPC"
            )
        } catch {
            // Expected: Iroh ownership is released before the fresh dial.
        }

        await router.releaseAllHeld()
        _ = try await connectTask.value

        #expect(shell.foregroundMacDeviceID == "mac-b")
        #expect(shell.activeTicket?.macDeviceID == "mac-b")
        #expect(shell.activeRoute == targetRoute)
        #expect(shell.connectedHostName == "Mac B")
        #expect(shell.selectedWorkspace?.macDeviceID == "mac-b")
        #expect(shell.selectedWorkspace?.rpcWorkspaceID.rawValue == "live-workspace")
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")] == nil)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")]?.client === oldClient)
        #expect(shell.secondaryMacSubscriptions.count
            == MobileShellComposite.maximumWarmControlConnectionCount)
        #expect(shell.liveMacConnections.filter {
            $0.role == .focused
        }.map(\.macDeviceID) == ["mac-b"])
        #expect(shell.liveMacConnections.first {
            $0.macDeviceID == "mac-a"
        }?.role == .control)
        #expect(shell.secondaryAggregationRetryTask == nil)
        #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")]?.status == .connected)
        #expect(shell.connections[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")]?.supportedHostCapabilities
            == Set(targetCapabilities))
        #expect(shell.connections[MacPairingKey(macDeviceID: "mac-b", instanceTag: "mmpool")]?.actionCapabilities.supportsCloseActions == true)
        do {
            _ = try await displacedControlClient.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "mobile.host.status",
                    params: [:]
                )
            )
            Issue.record("displaced control client unexpectedly remained usable")
        } catch {
            // Expected: the old control owner was retired before focus published.
        }
    }

    @Test func lateAnonymousIdentityRegistersFocusedConnection() async throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "late-identity",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let anonymousTicket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: anonymousTicket,
            allowsStackAuthFallback: true
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected
        )
        shell.remoteClient = client
        shell.activeTicket = anonymousTicket
        shell.activeRoute = route
        shell.supportedHostCapabilities = ["workspace.actions.v1"]

        await shell.applyHostReportedIdentity(
            client: client,
            deviceID: "mac-late",
            displayName: "Late Mac",
            instanceTag: "mmpool"
        )

        #expect(shell.foregroundMacDeviceIDForTesting() == "mac-late")
        #expect(shell.liveMacConnections == [
            MobileMacConnectionSnapshot(
                macDeviceID: "mac-late",
                displayName: "Late Mac",
                instanceTag: "mmpool",
                role: .focused,
                routeKind: .debugLoopback
            ),
        ])
        #expect(shell.connections["mac-late"]?.client === client)
    }

    @Test func officialBuildAdoptsUntagged06417OnlyFromAuthorizedTailscale() async throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "legacy-tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.17", port: 58_465)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: nil
        )
        let authorization = try CmxUserTailscalePairingAuthorization(
            host: "100.64.0.17",
            port: 58_465
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            userTailscalePairingAuthorization: authorization
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            buildCompatibilityPolicy: .official
        )
        shell.remoteClient = client
        shell.activeTicket = ticket
        shell.activeRoute = route

        await shell.applyHostReportedIdentity(
            client: client,
            deviceID: "legacy-mac",
            displayName: "Legacy Mac",
            instanceTag: nil,
            macAppVersion: "0.64.17"
        )

        #expect(shell.remoteClient === client)
        #expect(shell.foregroundMacDeviceIDForTesting() == "legacy-mac")
        #expect(shell.activeMacInstanceTag == nil)
    }

    @Test func officialBuildRejectsUntagged06417WithoutLocalTailscaleAuthority() async throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "untrusted-tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.17", port: 58_465)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: nil
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            buildCompatibilityPolicy: .official
        )
        shell.remoteClient = client
        shell.activeTicket = ticket
        shell.activeRoute = route

        await shell.applyHostReportedIdentity(
            client: client,
            deviceID: "untrusted-mac",
            displayName: "Untrusted Mac",
            instanceTag: nil,
            macAppVersion: "0.64.17"
        )

        #expect(shell.remoteClient == nil)
        #expect(shell.foregroundMacDeviceIDForTesting() == nil)
    }

    @Test func anonymousSameRouteRepairReleasesForegroundLeaseBeforeDial()
        async throws {
        let router = LivenessHostRouter()
        let clock = TestClock()
        let shell = try await makeConnectedStore(
            router: router,
            box: TransportBox(),
            clock: clock
        )
        let originalClient = try #require(shell.remoteClient)
        let route = try #require(shell.activeRoute)
        let anonymousTicket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: clock.now.addingTimeInterval(3_600)
        )

        _ = try await shell.connect(
            ticket: anonymousTicket,
            allowsStackAuthFallback: true
        )

        #expect(shell.connectionState == .connected)
        #expect(shell.remoteClient != nil)
        #expect(shell.remoteClient !== originalClient)
        #expect(shell.foregroundMacDeviceIDForTesting() == "test-mac")
        #expect(shell.connections["test-mac"]?.client === shell.remoteClient)
    }

    @Test func anonymousTargetRetiresWarmControlOnSamePhysicalRoute()
        async throws {
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "mac-after-rename",
            instanceTag: "new-tag",
            displayName: "New Name"
        )
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "anonymous-warm-control-route",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_590)
        )
        let controlTicket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-before-rename",
            macDisplayName: "Old Name",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let targetTicket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true
        )
        let controlClient = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: controlTicket,
            allowsStackAuthFallback: true,
            connectAttemptRegistry: shell.connectAttemptRegistry
        )
        let control = SecondaryMacSubscription(
            macDeviceID: controlTicket.macDeviceID,
            client: controlClient,
            route: route,
            ticket: controlTicket,
            storedInstanceTag: "old-tag",
            authenticatedInstanceTag: "old-tag",
            supportedHostCapabilities: ["events.v1"],
            actionCapabilities: .none,
            displayName: "Old Name"
        )
        shell.secondaryMacSubscriptions[control.ownerKey] = control
        shell.startSecondaryEventConsumer(control, displayName: "Old Name")
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))

        _ = try await shell.connect(
            ticket: targetTicket,
            allowsStackAuthFallback: true
        )

        #expect(control.isTransitioningToFocus)
        #expect(shell.secondaryMacSubscriptions[control.ownerKey] == nil)
        #expect(shell.connectionState == .connected)
        #expect(shell.foregroundMacDeviceIDForTesting() == "mac-after-rename")
    }

    @Test func sameMacRedialWaitsForLeaseHandoffButNotPhysicalClose()
        async throws {
        let router = LivenessHostRouter()
        let closeGate = LivenessTransportCloseGate()
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox(),
                closeGate: closeGate
            ),
            now: { clock.now }
        )
        let shell = MobileShellComposite.preview(runtime: runtime)
        shell.signIn()
        let ticket = try makeTicket(clock: clock)
        #expect(await shell.connectPairingURL(try attachURL(for: ticket)))
        let originalClient = try #require(shell.remoteClient)
        let initialWorkspaceRequests = await router.count(
            of: "workspace.list"
        )

        let redial = Task { @MainActor in
            try await shell.connect(
                ticket: ticket,
                allowsStackAuthFallback: true,
                pairedMacDeviceID: ticket.macDeviceID
            )
        }
        #expect(await closeGate.waitUntilCloseStarted())
        #expect(await router.waitForCount(
            of: "workspace.list",
            atLeast: initialWorkspaceRequests + 1
        ))
        let completion = await MobileShellComposite.raceAgainstDeadline(
            nanoseconds: 200_000_000
        ) {
            do {
                _ = try await redial.value
                return true
            } catch {
                return false
            }
        }

        #expect(completion.value == true)
        #expect(shell.connectionState == .connected)
        #expect(shell.remoteClient !== originalClient)
        await closeGate.release()
        _ = try? await redial.value
    }

    @Test func manualSameRouteRepairProbesBeforeReplacingForeground()
        async throws {
        let router = LivenessHostRouter()
        let shell = try await makeConnectedStore(
            router: router,
            box: TransportBox(),
            clock: TestClock()
        )
        let originalClient = try #require(shell.remoteClient)

        await shell.connectManualHost(
            name: "Test Mac",
            host: "127.0.0.1",
            port: 56_584,
            pairedMacDeviceID: "test-mac"
        )

        #expect(shell.connectionState == .connected)
        #expect(shell.connectionError == nil)
        #expect(shell.remoteClient != nil)
        #expect(shell.remoteClient !== originalClient)
        #expect(shell.foregroundMacDeviceIDForTesting() == "test-mac")
        #expect(await router.count(of: "mobile.attach_ticket.create") == 1)
    }

    @Test func failedManualSameRouteProbePreservesForeground()
        async throws {
        let router = LivenessHostRouter()
        let shell = try await makeConnectedStore(
            router: router,
            box: TransportBox(),
            clock: TestClock()
        )
        let originalClient = try #require(shell.remoteClient)
        let originalForegroundMacDeviceID =
            shell.foregroundMacDeviceIDForTesting()
        await router.failNextAttachTicketRequests()

        await shell.connectManualHost(
            name: "Test Mac",
            host: "127.0.0.1",
            port: 56_584,
            pairedMacDeviceID: "test-mac"
        )

        #expect(shell.connectionState == .connected)
        #expect(shell.remoteClient === originalClient)
        #expect(
            shell.foregroundMacDeviceIDForTesting()
                == originalForegroundMacDeviceID
        )
        #expect(await router.count(of: "mobile.attach_ticket.create") == 1)
        let hostStatusRequestsBeforeProof = await router.count(
            of: "mobile.host.status"
        )
        let proofRequest = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:]
        )
        _ = try await originalClient.sendRequest(proofRequest)
        #expect(
            await router.count(of: "mobile.host.status")
                == hostStatusRequestsBeforeProof + 1
        )
    }

    @Test func rejectedAnonymousIdentityPreservesAuthenticatedControlOwner()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "anonymous-authority-rejection",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-claimed",
            displayName: "Claimed Mac",
            routes: [route],
            instanceTag: "authenticated-owner",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let anonymousTicket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let claimedTicket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-claimed",
            macDisplayName: "Claimed Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let anonymousClient = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: anonymousTicket,
            allowsStackAuthFallback: true
        )
        let controlClient = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: claimedTicket,
            allowsStackAuthFallback: true
        )
        _ = try await controlClient.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.host.status",
                params: [:]
            )
        )
        let control = SecondaryMacSubscription(
            macDeviceID: "mac-claimed",
            client: controlClient,
            route: route,
            ticket: claimedTicket,
            storedInstanceTag: "authenticated-owner",
            authenticatedInstanceTag: "authenticated-owner",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        shell.remoteClient = anonymousClient
        shell.activeTicket = anonymousTicket
        shell.activeRoute = route
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-claimed", instanceTag: "authenticated-owner")] = control

        await shell.applyHostReportedIdentity(
            client: anonymousClient,
            deviceID: "mac-claimed",
            displayName: "Untrusted Alias",
            instanceTag: nil
        )

        #expect(shell.foregroundMacDeviceIDForTesting() == nil)
        #expect(shell.remoteClient == nil)
        #expect(shell.activeTicket == nil)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-claimed", instanceTag: "authenticated-owner")] === control)
        #expect(shell.connections[MacPairingKey(macDeviceID: "mac-claimed", instanceTag: "authenticated-owner")] == nil)
        _ = try await controlClient.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.host.status",
                params: [:]
            )
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-claimed", instanceTag: "authenticated-owner")] = nil
        control.cancel()
    }

    @Test func anonymousSwitchClearsPreviousFocusedIdentity() async throws {
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: nil,
            instanceTag: nil,
            displayName: nil
        )
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let route = try CmxAttachRoute(
            id: "anonymous-switch",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let previousTicket = try CmxAttachTicket(
            workspaceID: "workspace-a",
            terminalID: "terminal-a",
            macDeviceID: "mac-a",
            macDisplayName: "Mac A",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let previousClient = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: previousTicket,
            allowsStackAuthFallback: true
        )
        let anonymousTicket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected
        )
        shell.remoteClient = previousClient
        shell.foregroundMacDeviceID = "mac-a"
        shell.activeTicket = previousTicket
        shell.activeRoute = route
        shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")] = MacConnection(
            macDeviceID: "mac-a",
            ticket: previousTicket,
            route: route,
            client: previousClient,
            generation: UUID(),
            displayName: "Mac A",
            instanceTag: "mmpool",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )

        _ = try await shell.connect(
            ticket: anonymousTicket,
            allowsStackAuthFallback: true
        )

        #expect(shell.foregroundMacDeviceID == nil)
        #expect(shell.selectedWorkspace != nil)
        #expect(shell.selectedWorkspace?.macDeviceID == nil)
        #expect(shell.selectedWorkspace?.rpcWorkspaceID.rawValue == "live-workspace")
        #expect(shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")] == nil)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-a", instanceTag: "mmpool")] == nil)
        #expect(shell.remoteClient !== previousClient)
    }

    @Test func offlinePresenceKeepsCachedRowsUnavailable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "offline-row",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-offline",
            displayName: "Offline Mac",
            routes: [route],
            instanceTag: "offline-tag",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date()
        )
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-offline",
            macDisplayName: "Offline Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" }
        )
        shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-offline", instanceTag: "offline-tag")] = MacWorkspaceState(
            macDeviceID: "mac-offline",
            displayName: "Offline Mac",
            workspaces: [
                MobileWorkspacePreview(
                    id: .init(rawValue: "cached-workspace"),
                    name: "Cached Workspace",
                    terminals: []
                ),
            ],
            status: .connected
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-offline", instanceTag: "offline-tag")] = SecondaryMacSubscription(
            macDeviceID: "mac-offline",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "offline-tag",
            authenticatedInstanceTag: "offline-tag",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        shell.scheduleSecondaryAggregationRetry(macDeviceIDs: ["test-retry"])
        #expect(shell.secondaryAggregationRetryTask != nil)
        shell.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: "mac-offline",
                    tag: "offline-tag",
                    online: false
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        let removedAfterPresence = try await pollUntil {
            shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-offline", instanceTag: "offline-tag")] == nil
        }

        #expect(removedAfterPresence)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-offline", instanceTag: "offline-tag")] == nil)
        #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-offline", instanceTag: "offline-tag")]?.status == .unavailable)
        #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-offline", instanceTag: "offline-tag")]?.workspaces.map(\.name)
            == ["Cached Workspace"])
    }

    private static func pairedMac(
        id: String,
        instanceTag: String,
        isActive: Bool = false
    ) throws -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: id,
            routes: [try CmxAttachRoute(
                id: "\(id)-route",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.64.0.1", port: 50_922)
            )],
            createdAt: .distantPast,
            lastSeenAt: .distantPast,
            isActive: isActive,
            stackUserID: "user-1",
            teamID: "team-1",
            instanceTag: instanceTag
        )
    }

    private static func instance(
        deviceID: String,
        tag: String,
        online: Bool
    ) -> PresenceInstance {
        PresenceInstance(
            deviceId: deviceID,
            tag: tag,
            platform: "mac",
            online: online,
            lastSeenAt: 1_000
        )
    }

    private static func snapshot(
        _ instances: [PresenceInstance]
    ) -> PresenceUpdate {
        let devices = Dictionary(grouping: instances, by: \.deviceId)
            .map { deviceID, deviceInstances in
                PresenceDevice(
                    deviceId: deviceID,
                    platform: deviceInstances.first?.platform ?? "mac",
                    displayName: deviceInstances.first?.displayName,
                    online: deviceInstances.contains(where: \.online),
                    lastSeenAt: deviceInstances.map(\.lastSeenAt).max() ?? 0,
                    instances: deviceInstances
                )
            }
        return .snapshot(PresenceSnapshot(
            teamId: "team-1",
            now: 1_000,
            heartbeatIntervalMs: 15_000,
            offlineTimeoutMs: 45_000,
            devices: devices
        ))
    }
}

private func controlPoolWorkspaceUpdatedEventFrame() throws -> Data {
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "workspace.updated",
        "payload": [String: Any](),
    ]
    return try MobileSyncFrameCodec.encodeFrame(
        JSONSerialization.data(withJSONObject: envelope)
    )
}
