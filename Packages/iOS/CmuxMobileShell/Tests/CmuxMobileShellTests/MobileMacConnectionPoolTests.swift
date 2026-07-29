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
        #expect(MobileShellComposite.secondaryControlAttemptIsTransient(
            MobileShellConnectionError.rpcError(
                "request_timeout",
                "request timed out"
            )
        ))
        #expect(MobileShellComposite.secondaryControlAttemptIsTransient(
            MobileShellConnectionError.rpcError(
                "server_busy",
                "server is busy"
            )
        ))
        #expect(!MobileShellComposite.secondaryControlAttemptIsTransient(
            MobileShellConnectionError.rpcError(
                "unauthorized",
                "not authorized"
            )
        ))
        #expect(!MobileShellComposite.secondaryControlAttemptIsTransient(
            MobileShellConnectionError.rpcError(
                "method_not_found",
                "unsupported"
            )
        ))
        #expect(!MobileShellComposite.secondaryControlAttemptIsTransient(
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

        #expect(!MobileShellComposite.secondaryControlAttemptIsTransient(
            decodingError
        ))
        #expect(!MobileShellComposite.secondaryControlAttemptIsTransient(
            CmxNetworkByteTransportError.unsupportedRouteKind(.websocket)
        ))
        #expect(!MobileShellComposite.secondaryControlAttemptIsTransient(
            CancellationError()
        ))
        #expect(!MobileShellComposite.secondaryControlAttemptIsTransient(
            MobileShellConnectionError.routeCleanupBlocked
        ))
    }

    @Test func networkTransportFailuresRemainRetryable() {
        #expect(MobileShellComposite.secondaryControlAttemptIsTransient(
            CmxNetworkByteTransportError.connectionTimedOut
        ))
        #expect(MobileShellComposite.secondaryControlAttemptIsTransient(
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
        shell.workspacesByMac["mac-racing"] = MacWorkspaceState(
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
        #expect(shell.secondaryMacSubscriptions["mac-racing"] == nil)

        await router.releaseAllHeld()
        #expect(try await pollUntil {
            shell.workspacesByMac["mac-racing"]?.status == .unavailable
        })
        #expect(shell.secondaryMacSubscriptions["mac-racing"] == nil)
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
        #expect(shell.secondaryMacSubscriptions["mac-single-flight"] != nil)
        shell.secondaryMacSubscriptions["mac-single-flight"]?.cancel()
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

        #expect(shell.secondaryMacSubscriptions["mac-targeted"] == nil)
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
            shell.secondaryMacSubscriptions[mac.macDeviceID] =
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
        shell.secondaryMacSubscriptions[existing.macDeviceID] =
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

        #expect(!MobileShellComposite.warmControlPoolHasCapacity(
            currentControlCount: capacity,
            vacatesControlSlot: false
        ))
        #expect(MobileShellComposite.warmControlPoolHasCapacity(
            currentControlCount: capacity,
            vacatesControlSlot: true
        ))
        #expect(!MobileShellComposite.warmControlPoolHasCapacity(
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
            shell.secondaryMacSubscriptions["mac-refresh-only"] != nil
                && shell.workspacesByMac["mac-refresh-only"]?.status
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
            shell.secondaryMacSubscriptions["mac-refresh-only"] == nil
        })
        #expect(shell.workspacesByMac["mac-refresh-only"]?.status
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
            shell.secondaryMacSubscriptions["mac-permanent-refresh"] != nil
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
            shell.secondaryMacSubscriptions["mac-permanent-refresh"] == nil
        })
        await closeGate.waitUntilCloseStarted()
        #expect(
            shell.secondaryMacDrainReservations["mac-permanent-refresh"]
                != nil
        )
        #expect(shell.workspacesByMac["mac-permanent-refresh"]?.status
            == .unavailable)
        #expect(!shell.secondaryRetryBackoffIsScheduledForTesting())
        let workspaceRequests = await router.count(of: "workspace.list")
        clock.advance(by: .seconds(60))
        for _ in 0 ..< 8 { await Task.yield() }
        #expect(await router.count(of: "workspace.list") == workspaceRequests)
        await closeGate.release()
        #expect(try await pollUntil {
            shell.secondaryMacDrainReservations["mac-permanent-refresh"]
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
                "mac-authority-replacement"
            ]?.storedInstanceTag == "tag-a"
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
        await closeGate.waitUntilCloseStarted()

        #expect(
            await router.count(of: "mobile.host.status")
                == firstHostStatusCount
        )
        #expect(
            shell.secondaryMacSubscriptions[
                "mac-authority-replacement"
            ] == nil
        )
        #expect(
            shell.secondaryMacDrainReservations[
                "mac-authority-replacement"
            ] != nil
        )
        #expect(!shell.secondaryRetryBackoffIsScheduledForTesting())

        await closeGate.release()
        #expect(try await pollUntil {
            shell.secondaryRetryBackoffIsScheduledForTesting()
        })
        clock.advance(by: .seconds(2))
        #expect(await router.waitForCount(
            of: "mobile.host.status",
            atLeast: firstHostStatusCount + 1
        ))
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions[
                "mac-authority-replacement"
            ]?.storedInstanceTag == "tag-b"
        })
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

        shell.beginSecondaryRetryBackoffForTesting(
            macDeviceIDs: ["mac-newer-targeted-failure"]
        )
        #expect(shell.secondaryRetryBackoffIsScheduledForTesting())

        await pairedStore.release(teamID: "team-1")
        await staleFullPass.value

        #expect(shell.secondaryRetryBackoffIsScheduledForTesting())
        #expect(shell.secondaryRetryMacIDsForTesting()
            == ["mac-newer-targeted-failure"])
        shell.resetSecondaryRetryBackoffForTesting()
    }

    @Test func staleRetryCompletionCannotClearReplacementTimer() async throws {
        let clock = ControlPoolManualClock()
        let shell = MobileShellComposite(
            isSignedIn: true,
            presence: IdlePresence(),
            controlPlaneSchedulingClock: clock
        )
        shell.beginSecondaryRetryBackoffForTesting()
        #expect(try await pollUntil { clock.sleeperCount == 1 })

        // Wake the old task without yielding the MainActor, then replace it.
        // Its continuation is queued but must not own the new timer's state.
        clock.advance(by: .seconds(2))
        shell.resetSecondaryRetryBackoffForTesting()
        shell.beginSecondaryRetryBackoffForTesting()
        #expect(try await pollUntil { clock.sleeperCount == 1 })
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(shell.secondaryRetryBackoffIsScheduledForTesting())
        #expect(shell.secondaryRetryMacIDsForTesting() == ["test-retry"])
        shell.resetSecondaryRetryBackoffForTesting()
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
        shell.beginSecondaryRetryBackoffForTesting()
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
            shell.secondaryRetryMacIDsForTesting().contains("mac-new")
        })
        #expect(shell.secondaryMacSubscriptions["mac-new"] == nil)
        shell.resetSecondaryRetryBackoffForTesting()
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
        shell.secondaryMacSubscriptions["mac-promoting"] = subscription

        await shell.refreshSecondaryMacWorkspaces()

        #expect(shell.secondaryMacSubscriptions["mac-promoting"] === subscription)
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
        shell.connections["mac-provisional"] = focused
        #expect(shell.transitionFocusedConnectionToControl(
            provisional,
            replacing: focused
        ))

        await shell.refreshSecondaryMacWorkspaces()

        #expect(shell.secondaryMacSubscriptions["mac-provisional"]
            === provisional)
        provisional.detachKeepingClient()
        shell.secondaryMacSubscriptions["mac-provisional"] = nil
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

        #expect(shell.secondaryMacSubscriptions["mac-permanent"] == nil)
        #expect(!shell.secondaryRetryBackoffIsScheduledForTesting())
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
            shell.secondaryRetryBackoffIsScheduledForTesting()
        })
        #expect(shell.secondaryMacSubscriptions["mac-transient"] == nil)
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
            shell.secondaryMacSubscriptions["mac-auth"] != nil
        })
        #expect(await router.count(of: "mobile.host.status") == 2)
        #expect(tokenRequests.count > 0)
        #expect(!shell.secondaryRetryBackoffIsScheduledForTesting())
        if let subscription = shell.secondaryMacSubscriptions["mac-auth"] {
            subscription.cancel()
            shell.secondaryMacSubscriptions["mac-auth"] = nil
            await subscription.client.disconnect()
        }
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
        shell?.secondaryMacSubscriptions["mac-retain"] = subscription
        shell?.startSecondaryEventConsumer(subscription, displayName: "Retain Mac")

        shell = nil

        #expect(weakShell == nil)
        subscription.cancel()
    }

    @Test func failedTerminalUnsubscribeDisconnectsInsteadOfDemoting() async throws {
        let router = LivenessHostRouter()
        await router.invalidateUnsubscribeRequest(number: 1)
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
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
        shell.connections["mac-a"] = connection

        let terminalStopped = await shell.prepareFocusedConnectionForHandoff(
            connection
        )
        await shell.commitFocusedConnectionHandoff(
            connection,
            terminalStopped: terminalStopped,
            retainAsControl: true
        )

        #expect(!terminalStopped)
        #expect(shell.connections["mac-a"] == nil)
        #expect(shell.secondaryMacSubscriptions["mac-a"] == nil)
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
        shell.connections["mac-focused"] = focused
        shell.secondaryMacSubscriptions["mac-focused"] = rejectedControl

        #expect(shell.connections["mac-focused"]?.client === focusedClient)
        #expect(shell.secondaryMacSubscriptions["mac-focused"] == nil)

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
        shell.secondaryMacSubscriptions["mac-control"] = control
        shell.connections["mac-control"] = rejectedFocused

        #expect(shell.secondaryMacSubscriptions["mac-control"] === control)
        #expect(shell.connections["mac-control"] == nil)
        rejectedControl.cancel()
        control.cancel()
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
        shell.connections["mac-a"] = current

        await shell.installControlConnection(from: stale)
        shell.invalidateFocusedConnectionAfterAbortedHandoff(stale)

        #expect(shell.connections["mac-a"]?.generation == currentGeneration)
        #expect(shell.secondaryMacSubscriptions["mac-a"] == nil)
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

        #expect(shell.connections["mac-a"] == nil)
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
        shell.connections["mac-a"] = connection

        await shell.installControlConnection(from: connection)

        #expect(shell.connections["mac-a"] == nil)
        #expect(shell.secondaryMacSubscriptions["mac-a"]?.client === client)
        #expect(try await pollUntil { clock.sleeperCount == 1 })
        #expect(await router.count(of: "mobile.events.subscribe") == 0)

        shell.secondaryMacSubscriptions["mac-a"]?.detachKeepingClient()
        shell.secondaryMacSubscriptions["mac-a"] = nil
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
        shell.connections["mac-a"] = connection

        #expect(await shell.prepareFocusedConnectionForHandoff(connection))
        #expect(shell.focusedHandoffPreparedGenerations.contains(
            focusedGeneration
        ))

        let restoreGeneration = UUID()
        shell.connectionGeneration = restoreGeneration
        shell.invalidateFocusedConnectionAfterAbortedHandoff(connection)

        #expect(shell.connections["mac-a"]?.generation == focusedGeneration)
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
        shell.workspacesByMac["mac-invalid"] = MacWorkspaceState(
            macDeviceID: "mac-invalid",
            displayName: "Invalid Mac",
            workspaces: [],
            status: .connected
        )
        shell.secondaryMacSubscriptions["mac-invalid"] = subscription

        shell.startSecondaryEventConsumer(
            subscription,
            displayName: "Invalid Mac"
        )

        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions["mac-invalid"] == nil
        })
        #expect(shell.workspacesByMac["mac-invalid"]?.status == .unavailable)
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
        shell.secondaryMacSubscriptions["mac-b"] = subscription
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
                subscription,
                macDeviceID: "mac-b"
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
        shell.secondaryMacSubscriptions["mac-b"] = nil
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
        shell.secondaryMacSubscriptions["mac-a"] = first
        shell.startSecondaryEventConsumer(first, displayName: "Mac A")
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))
        shell.secondaryMacSubscriptions["mac-b"] = second
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
                target,
                macDeviceID: targetMacID
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
        shell.secondaryMacSubscriptions["mac-a"] = nil
        shell.secondaryMacSubscriptions["mac-b"] = nil
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
        shell.secondaryMacSubscriptions["mac-b"] = subscription
        shell.startSecondaryEventConsumer(subscription, displayName: "Mac B")

        #expect(try await pollUntil {
            let feedFetchCount = await router.count(
                of: "notification.feed.list"
            )
            return subscription.hasActivatedControlStream
                && shell.workspacesByMac["mac-b"]?.workspaces.first?.name
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
        shell.notificationFeedKnownRevisionsByMac["mac-b"] = 3
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
            return shell.workspacesByMac["mac-b"]?.workspaces.first?.name
                == "Event Fresh Catch-up"
                && feedFetchCount >= feedFetchesBeforeGap + 2
        })
        #expect(shell.secondaryMacSubscriptions["mac-b"] === subscription)

        await router.failNextNotificationFeedLists()
        await router.dropSubscription()
        clock.advance(by: .seconds(20))

        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 3
        ))
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions["mac-b"] == nil
        })
        #expect(shell.workspacesByMac["mac-b"]?.status == .unavailable)
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
        shell.secondaryMacSubscriptions["mac-b"] = subscription
        shell.startSecondaryEventConsumer(subscription, displayName: "Mac B")
        #expect(try await pollUntil {
            subscription.hasActivatedControlStream
                && shell.workspacesByMac["mac-b"]?.workspaces.first?.name
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
                shell.workspacesByMac["mac-b"]?.workspaces.first?.name
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
            shell.workspacesByMac["mac-b"]?.workspaces.first?.name
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
            subscription,
            macDeviceID: "mac-b"
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
            shell.workspacesByMac["mac-b"]?.workspaces.first?.name
                == "Deferred Fresh Snapshot"
        })
        #expect(await router.count(of: "workspace.list") == 4)
        #expect(shell.secondaryMacSubscriptions["mac-b"] === subscription)

        subscription.detachKeepingClient()
        shell.secondaryMacSubscriptions["mac-b"] = nil
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
        shell.secondaryMacSubscriptions["mac-b"] = subscription
        shell.startSecondaryEventConsumer(subscription, displayName: "Mac B")

        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))
        #expect(try await pollUntil {
            shell.secondaryMacSubscriptions["mac-b"] == nil
        })
        #expect(shell.workspacesByMac["mac-b"]?.status != .connected)
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
        shell.secondaryMacSubscriptions["mac-b"] = subscription
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
                subscription,
                macDeviceID: "mac-b"
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
        shell.secondaryMacSubscriptions["mac-b"] = nil
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
        shell.secondaryMacSubscriptions["mac-b"] = subscription
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
            subscription,
            macDeviceID: "mac-b"
        )))
        #expect(subscription.isTransitioningToFocus)
        #expect(shell.secondaryMacSubscriptions["mac-b"] == nil)
        #expect(shell.workspacesByMac["mac-b"]?.status != .connected)

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
        shell.secondaryMacSubscriptions["mac-a"] = first
        shell.startSecondaryEventConsumer(first, displayName: "Mac A")
        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))
        #expect(try await pollUntil {
            first.hasActivatedControlStream && clock.sleeperCount == 1
        })

        await router.holdSubscribeRequest(number: 2)
        shell.secondaryMacSubscriptions["mac-b"] = second
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
            shell.secondaryMacSubscriptions["mac-b"] == nil
        })
        #expect(await router.count(of: "mobile.events.subscribe") == 3)

        first.detachKeepingClient()
        second.detachKeepingClient()
        shell.secondaryMacSubscriptions["mac-a"] = nil
        shell.secondaryMacSubscriptions["mac-b"] = nil
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
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
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
        shell.connections["mac-a"] = MacConnection(
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
        shell.workspacesByMac["mac-a"] = MacWorkspaceState(
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
        shell.secondaryMacSubscriptions["mac-b"] = displacedControl
        for index in 0 ..<
            MobileShellComposite.maximumWarmControlConnectionCount - 1 {
            let macDeviceID = "mac-fill-\(index)"
            let fillerTicket = try CmxAttachTicket(
                workspaceID: "",
                terminalID: nil,
                macDeviceID: macDeviceID,
                macDisplayName: macDeviceID,
                routes: [targetRoute],
                expiresAt: Date().addingTimeInterval(3_600)
            )
            shell.secondaryMacSubscriptions[macDeviceID] =
                SecondaryMacSubscription(
                    macDeviceID: macDeviceID,
                    client: MobileCoreRPCClient(
                        runtime: runtime,
                        route: targetRoute,
                        ticket: fillerTicket,
                        allowsStackAuthFallback: true
                    ),
                    route: targetRoute,
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
        #expect(shell.secondaryMacSubscriptions["mac-b"] == nil)
        #expect(shell.secondaryMacSubscriptions["mac-a"]?.client === oldClient)
        #expect(shell.secondaryMacSubscriptions.count
            == MobileShellComposite.maximumWarmControlConnectionCount)
        #expect(shell.liveMacConnections.filter {
            $0.role == .focused
        }.map(\.macDeviceID) == ["mac-b"])
        #expect(shell.liveMacConnections.first {
            $0.macDeviceID == "mac-a"
        }?.role == .control)
        #expect(!shell.secondaryRetryBackoffIsScheduledForTesting())
        #expect(shell.workspacesByMac["mac-b"]?.status == .connected)
        #expect(shell.connections["mac-b"]?.supportedHostCapabilities
            == Set(targetCapabilities))
        #expect(shell.connections["mac-b"]?.actionCapabilities.supportsCloseActions == true)
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

        await shell.applyHostReportedIdentityForTesting(
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
                role: .focused
            ),
        ])
        #expect(shell.connections["mac-late"]?.client === client)
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
        shell.connections["mac-a"] = MacConnection(
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
        #expect(shell.connections["mac-a"] == nil)
        #expect(shell.secondaryMacSubscriptions["mac-a"] == nil)
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
        shell.workspacesByMac["mac-offline"] = MacWorkspaceState(
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
        shell.secondaryMacSubscriptions["mac-offline"] = SecondaryMacSubscription(
            macDeviceID: "mac-offline",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "offline-tag",
            authenticatedInstanceTag: "offline-tag",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        shell.beginSecondaryRetryBackoffForTesting()
        #expect(shell.secondaryRetryBackoffIsScheduledForTesting())
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
            shell.secondaryMacSubscriptions["mac-offline"] == nil
        }

        #expect(removedAfterPresence)
        #expect(shell.secondaryMacSubscriptions["mac-offline"] == nil)
        #expect(shell.workspacesByMac["mac-offline"]?.status == .unavailable)
        #expect(shell.workspacesByMac["mac-offline"]?.workspaces.map(\.name)
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

private struct IdlePresence: PresenceSubscribing {
    func subscribe() async throws -> AsyncThrowingStream<PresenceUpdate, any Error> {
        AsyncThrowingStream { _ in }
    }
}

private final class PoolTransportAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

private struct FailingPoolTransportFactory: CmxByteTransportFactory {
    let attempts: PoolTransportAttemptCounter

    func makeTransport(
        for route: CmxAttachRoute
    ) throws -> any CmxByteTransport {
        attempts.increment()
        throw MobileShellConnectionError.connectionClosed
    }
}

private actor PromotionFenceCompletion {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}

private actor ControlPoolRouteSyncGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
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

private final class ControlPoolManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: UnsafeContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var preCancelledIDs: Set<UUID> = []

    var now: Instant {
        lock.withLock { current }
    }

    var minimumResolution: Duration { .zero }

    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<Void, any Error>) in
                lock.lock()
                if preCancelledIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers.append(Sleeper(
                        id: id,
                        deadline: deadline,
                        continuation: continuation
                    ))
                    lock.unlock()
                }
            }
        } onCancel: {
            cancelSleeper(id: id)
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let due = sleepers
            .filter { $0.deadline <= current }
            .sorted { $0.deadline < $1.deadline }
        sleepers.removeAll { $0.deadline <= current }
        lock.unlock()
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    private func cancelSleeper(id: UUID) {
        lock.lock()
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
            preCancelledIDs.insert(id)
            lock.unlock()
            return
        }
        let sleeper = sleepers.remove(at: index)
        lock.unlock()
        sleeper.continuation.resume(throwing: CancellationError())
    }
}
