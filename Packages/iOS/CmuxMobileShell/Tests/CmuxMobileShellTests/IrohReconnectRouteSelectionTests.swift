import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import SQLite3
import Testing
@testable import CmuxMobileShell

@MainActor
extension ReconnectRouteSelectionTests {
    @Test func manualReconnectRedialsWhenLiveStreamIsUnavailableButRPCStateIsConnected() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let store = try await makeReconnectStore(
            routes: [try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh]
            )
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.connectionState == .connected)
        #expect(factory.attemptedKinds() == [.iroh])

        // The terminal stream can fail before the underlying RPC client notices
        // its transport has closed. This is the exact state rendered by the
        // workspace list's Disconnected banner and Reconnect button.
        store.markMacConnectionUnavailableIfNeeded(after: MobileShellConnectionError.connectionClosed)
        #expect(store.connectionState == .connected)
        #expect(store.workspaceListConnectionStatus == .unavailable)

        await store.reconnectOrRefresh()

        #expect(factory.attemptedKinds() == [.iroh, .iroh])
        #expect(store.connectionState == .connected)
        #expect(store.workspaceListConnectionStatus == .connected)
    }

    @Test func reconnectActiveMacUsesPersistedIrohBeforeNetworkFallback() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let store = try await makeReconnectStore(
            routes: [try tailscale(), try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.connectionState == .connected)
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(store.activeRoute?.kind == .iroh)
        #expect(await router.workspaceIDs(for: "workspace.list") == [nil])
        #expect(store.workspaces.map(\.rpcWorkspaceID.rawValue) == ["live-workspace"])
    }

    @Test func rejectedIrohReconnectNeverDowngradesToRawTailscale() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box, failingKinds: [.iroh])
        let store = try await makeReconnectStore(
            routes: [try tailscale(), try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(store.connectionState == .disconnected)
        #expect(factory.attemptedKinds() == [.iroh])
    }

    @Test func legacyMacWithoutIrohFailsClosedInsteadOfSendingBearerOverTCP() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let store = try await makeReconnectStore(
            routes: [try tailscale()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(factory.attemptedKinds().isEmpty)
    }

    @Test func preIrohPairingContinuesOverItsExactTailscaleRouteAfterIOSUpgrade() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("paired-macs.sqlite3")
        try seedVersionSevenPairing(
            at: databaseURL,
            route: tailscale(),
            stackUserID: "user-1"
        )
        let pairedStore = try MobilePairedMacStore(databaseURL: databaseURL)
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "iroh-tailscale-upgrade-\(UUID().uuidString)"
            )!
        )
        await store.loadPairedMacs()

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.connectionState == .connected)
        #expect(factory.attemptedKinds() == [.tailscale])
        #expect(
            factory.attemptedAuthorizationModes()
                == [.legacyTailscaleBearer(
                    try CmxLegacyTailscaleAuthorizationEvidence(
                        macDeviceID: "test-mac",
                        host: "100.82.214.112",
                        port: 50_906
                    )
                )]
        )
        #expect(store.activeRoute?.kind == .tailscale)
    }

    @Test func reconnectUsesSingleRegistrySnapshotToRescueNonActiveMacWithNoLocalRoutes() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "mac-b", instanceTag: "stable", displayName: "Mac B")
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let good = try registryIroh(
            id: "iroh-b",
            endpointID: String(repeating: "b", count: 64)
        )
        let wrong = try registryIroh(
            id: "iroh-wrong",
            endpointID: String(repeating: "c", count: 64)
        )
        let registry = SnapshotCountingDeviceRegistry(outcome: .ok([
            RegistryDevice(
                deviceId: "mac-b",
                platform: "mac",
                displayName: "Mac B",
                lastSeenAt: clock.now,
                instances: [
                    RegistryAppInstance(tag: "other", routes: [wrong], lastSeenAt: clock.now),
                    RegistryAppInstance(
                        tag: "stable",
                        routes: [good, try tailscale(51_002)],
                        lastSeenAt: clock.now
                    ),
                ]
            ),
        ]))
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [try tailscale(51_001)],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Mac B",
            routes: [],
            instanceTag: "stable",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now.addingTimeInterval(1)
        )
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.foregroundMacDeviceID == "mac-b")
        #expect(store.activeRoute?.id == "iroh-b")
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(await registry.counts() == .init(list: 1, fresh: 0))
        let rows = try await pairedStore.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(rows.count == 2)
        let upgraded = try #require(rows.first { $0.macDeviceID == "mac-b" })
        #expect(upgraded.instanceTag == "stable")
        #expect(upgraded.routes.contains { $0.id == "iroh-b" })
    }

    @Test func reconnectManyLegacyMacsReadsOnePostRegistryStoreSnapshot() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(
            router: router,
            box: box,
            failingKinds: [.iroh]
        )
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let macCount = 32
        var records: [MobilePairedMac] = []
        var devices: [RegistryDevice] = []
        for index in 0..<macCount {
            let deviceID = "mac-\(index)"
            let iroh = try registryIroh(
                id: "iroh-\(index)",
                endpointID: String(format: "%064x", index + 1)
            )
            records.append(MobilePairedMac(
                macDeviceID: deviceID,
                displayName: "Mac \(index)",
                routes: [try tailscale(52_000 + index)],
                createdAt: clock.now,
                lastSeenAt: clock.now.addingTimeInterval(Double(index)),
                isActive: index == 0,
                stackUserID: "user-1",
                instanceTag: "stable"
            ))
            devices.append(RegistryDevice(
                deviceId: deviceID,
                platform: "mac",
                displayName: "Mac \(index)",
                lastSeenAt: clock.now,
                instances: [
                    RegistryAppInstance(
                        tag: "stable",
                        routes: [iroh],
                        lastSeenAt: clock.now
                    ),
                ]
            ))
        }
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": records],
            blockedTeams: []
        )
        let registry = SnapshotCountingDeviceRegistry(outcome: .ok(devices))
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )
        await pairedStore.resetLoadAllCount()

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(factory.attemptedKinds() == Array(repeating: .iroh, count: macCount))
        #expect(await registry.counts() == .init(list: 1, fresh: 0))
        #expect(await pairedStore.currentLoadAllCount() == 2)
    }

    @Test func concurrentPresenceUpgradeIsUsedWhenRegistryReturnsTheSameIrohRoutes() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "test-mac", instanceTag: "stable")
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let iroh = try registryIroh(
            id: "iroh-stable",
            endpointID: String(repeating: "e", count: 64)
        )
        let legacy = try tailscale(51_007)
        let publishedRoutes = [iroh, legacy]
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [legacy],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let registry = PresenceRacingDeviceRegistry(
            pairedStore: pairedStore,
            routes: publishedRoutes,
            outcome: .ok([
                RegistryDevice(
                    deviceId: "test-mac",
                    platform: "mac",
                    displayName: "Test Mac",
                    lastSeenAt: clock.now,
                    instances: [
                        RegistryAppInstance(
                            tag: "stable",
                            routes: publishedRoutes,
                            lastSeenAt: clock.now
                        ),
                    ]
                ),
            ]),
            now: clock.now.addingTimeInterval(1)
        )
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.activeRoute?.id == iroh.id)
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(store.connectionError?.localizedCaseInsensitiveContains("update cmux") != true)
        #expect(await registry.state() == .init(listCalls: 1, wrotePresenceRoutes: true))
        let persisted = try #require(await pairedStore.activeMac(
            stackUserID: "user-1",
            teamID: nil
        ))
        #expect(persisted.routes.contains { $0.id == iroh.id })
    }

    @Test func concurrentPresenceUpgradeWinsWhenRegistrySnapshotHasNoMatchingDevice() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "test-mac", instanceTag: "stable")
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let iroh = try registryIroh(
            id: "iroh-presence",
            endpointID: String(repeating: "f", count: 64)
        )
        let legacy = try tailscale(51_008)
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [legacy],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let registry = PresenceRacingDeviceRegistry(
            pairedStore: pairedStore,
            routes: [iroh, legacy],
            outcome: .ok([]),
            now: clock.now.addingTimeInterval(1)
        )
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.activeRoute?.id == iroh.id)
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(store.connectionError?.localizedCaseInsensitiveContains("update cmux") != true)
    }

    @Test func changedTailscaleOnlyRowIsNeverReturnedAsAReconnectRoute() async throws {
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: KindRecordingTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox()
            ),
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let captured = MobilePairedMac(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try tailscale(51_012)],
            createdAt: clock.now,
            lastSeenAt: clock.now,
            isActive: true,
            stackUserID: "user-1",
            instanceTag: "stable"
        )
        var current = captured
        current.routes = [try tailscale(51_013)]
        current.lastSeenAt = clock.now.addingTimeInterval(1)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [current]],
            blockedTeams: []
        )
        let registryDevice = RegistryDevice(
            deviceId: current.macDeviceID,
            platform: "mac",
            displayName: current.displayName,
            lastSeenAt: current.lastSeenAt,
            instances: [
                RegistryAppInstance(
                    tag: "stable",
                    routes: current.routes,
                    lastSeenAt: current.lastSeenAt
                ),
            ]
        )
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: SnapshotCountingDeviceRegistry(outcome: .ok([registryDevice])),
            runtime: runtime
        )
        let scope = try #require(await store.currentScopeSnapshot(userID: "user-1"))
        let outcome = await store.freshReconnectRoutesAfterLocalFailure(
            for: captured,
            scope: scope,
            snapshot: ReconnectRefreshSnapshot(
                pairedMacs: [current],
                registryDevices: [registryDevice]
            )
        )

        guard case .confirmedMissingIroh = outcome else {
            Issue.record("Expected an authenticated missing-Iroh result")
            return
        }
    }

    @Test func reconnectRevalidatesMissingIrohBeforeShowingUpdateGuidance() async throws {
        let clock = TestClock()
        let factory = KindRecordingTransportFactory(
            router: LivenessHostRouter(),
            box: TransportBox()
        )
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let legacy = MobilePairedMac(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try tailscale(51_014)],
            createdAt: clock.now,
            lastSeenAt: clock.now,
            isActive: true,
            stackUserID: "user-1",
            instanceTag: "stable"
        )
        var upgraded = legacy
        upgraded.routes = [
            try registryIroh(
                id: "iroh-current",
                endpointID: String(repeating: "a", count: 64)
            ),
            legacy.routes[0],
        ]
        upgraded.lastSeenAt = clock.now.addingTimeInterval(1)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [legacy]],
            blockedTeams: []
        )
        let registry = SnapshotCountingDeviceRegistry(outcome: .ok([
            RegistryDevice(
                deviceId: legacy.macDeviceID,
                platform: "mac",
                displayName: legacy.displayName,
                lastSeenAt: legacy.lastSeenAt,
                instances: [
                    RegistryAppInstance(
                        tag: "stable",
                        routes: legacy.routes,
                        lastSeenAt: legacy.lastSeenAt
                    ),
                ]
            ),
        ]))
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )
        await pairedStore.resetLoadAllCount()
        await pairedStore.replaceRecords(
            afterLoadAllCount: 2,
            teamID: nil,
            with: [upgraded]
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(factory.attemptedKinds().isEmpty)
        let copy = [store.connectionError, store.connectionErrorGuidance]
            .compactMap { $0 }
            .joined(separator: " ")
        #expect(!copy.localizedCaseInsensitiveContains("update cmux"))
    }

    @Test func switchRevalidatesMissingIrohBeforeShowingUpdateGuidance() async throws {
        let clock = TestClock()
        let factory = KindRecordingTransportFactory(
            router: LivenessHostRouter(),
            box: TransportBox()
        )
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let legacy = MobilePairedMac(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try tailscale(51_015)],
            createdAt: clock.now,
            lastSeenAt: clock.now,
            isActive: true,
            stackUserID: "user-1",
            instanceTag: "stable"
        )
        var upgraded = legacy
        upgraded.routes = [
            try registryIroh(
                id: "iroh-current",
                endpointID: String(repeating: "b", count: 64)
            ),
            legacy.routes[0],
        ]
        upgraded.lastSeenAt = clock.now.addingTimeInterval(1)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [legacy]],
            blockedTeams: []
        )
        let registry = SnapshotCountingDeviceRegistry(outcome: .ok([
            RegistryDevice(
                deviceId: legacy.macDeviceID,
                platform: "mac",
                displayName: legacy.displayName,
                lastSeenAt: legacy.lastSeenAt,
                instances: [
                    RegistryAppInstance(
                        tag: "stable",
                        routes: legacy.routes,
                        lastSeenAt: legacy.lastSeenAt
                    ),
                ]
            ),
        ]))
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )
        await pairedStore.resetLoadAllCount()
        await pairedStore.replaceRecords(
            afterLoadAllCount: 2,
            teamID: nil,
            with: [upgraded]
        )

        #expect(!(await store.switchToMac(macDeviceID: "test-mac")))
        #expect(factory.attemptedKinds().isEmpty)
        let copy = [store.connectionError, store.connectionErrorGuidance]
            .compactMap { $0 }
            .joined(separator: " ")
        #expect(!copy.localizedCaseInsensitiveContains("update cmux"))
    }

    @Test func ambiguousRegistryAuthorityDoesNotClaimTheMacNeedsAnUpdate() async throws {
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: KindRecordingTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox()
            ),
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let legacy = try tailscale(51_009)
        let registry = SnapshotCountingDeviceRegistry(outcome: .ok([
            RegistryDevice(
                deviceId: "test-mac",
                platform: "mac",
                displayName: "Test Mac",
                lastSeenAt: clock.now,
                instances: [
                    RegistryAppInstance(
                        tag: "stable",
                        routes: [try registryIroh(
                            id: "iroh-a",
                            endpointID: String(repeating: "a", count: 64)
                        )],
                        lastSeenAt: clock.now
                    ),
                    RegistryAppInstance(
                        tag: "stable",
                        routes: [try registryIroh(
                            id: "iroh-b",
                            endpointID: String(repeating: "b", count: 64)
                        )],
                        lastSeenAt: clock.now
                    ),
                ]
            ),
        ]))
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [legacy],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        let copy = [store.connectionError, store.connectionErrorGuidance]
            .compactMap { $0 }
            .joined(separator: " ")
        #expect(!copy.localizedCaseInsensitiveContains("update cmux"))
    }

    @Test func switchToLegacySavedMacUpgradesFromRegistryWithoutRescan() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "test-mac", instanceTag: "stable")
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let iroh = try registryIroh(
            id: "iroh-stable",
            endpointID: String(repeating: "d", count: 64)
        )
        let legacy = try tailscale(51_003)
        let registry = SnapshotCountingDeviceRegistry(outcome: .ok([
            RegistryDevice(
                deviceId: "test-mac",
                platform: "mac",
                displayName: "Test Mac",
                lastSeenAt: clock.now,
                instances: [
                    RegistryAppInstance(
                        tag: "stable",
                        routes: [iroh, legacy],
                        lastSeenAt: clock.now
                    ),
                ]
            ),
        ]))
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [legacy],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let before = try #require(await pairedStore.activeMac(stackUserID: "user-1", teamID: nil))
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )

        #expect(await store.switchToMac(macDeviceID: "test-mac"))
        #expect(await registry.counts() == .init(list: 1, fresh: 0))
        #expect(store.activeRoute?.id == iroh.id)
        #expect(!store.connectionRequiresReauth)
        let after = try #require(await pairedStore.activeMac(stackUserID: "user-1", teamID: nil))
        #expect(after.createdAt == before.createdAt)
        #expect(after.isActive)
        #expect(after.routes.contains { $0.id == iroh.id })
    }

    @Test func switchUpgradesLegacyTargetWhileAnotherMacStaysConnected() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let macAIroh = try registryIroh(
            id: "iroh-a",
            endpointID: String(repeating: "a", count: 64)
        )
        let macBIroh = try registryIroh(
            id: "iroh-b",
            endpointID: String(repeating: "b", count: 64)
        )
        let macBLegacy = try tailscale(51_005)
        let registry = SnapshotCountingDeviceRegistry(outcome: .ok([
            RegistryDevice(
                deviceId: "mac-b",
                platform: "mac",
                displayName: "Mac B",
                lastSeenAt: clock.now,
                instances: [
                    RegistryAppInstance(
                        tag: "stable",
                        routes: [macBIroh, macBLegacy],
                        lastSeenAt: clock.now
                    ),
                ]
            ),
        ]))
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [macAIroh],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Mac B",
            routes: [macBLegacy],
            instanceTag: "stable",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now.addingTimeInterval(1)
        )
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )
        await router.setHostIdentity(deviceID: "mac-a", instanceTag: "stable")
        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.foregroundMacDeviceID == "mac-a")

        await router.setHostIdentity(deviceID: "mac-b", instanceTag: "stable")
        #expect(await store.switchToMac(macDeviceID: "mac-b"))
        #expect(store.foregroundMacDeviceID == "mac-b")
        #expect(store.activeRoute?.id == macBIroh.id)
        #expect(await registry.counts() == .init(list: 1, fresh: 0))
    }

    @Test func legacySavedMacWithoutPublishedIrohIsRetainedAndRequestsMacUpdate() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = try tailscale(51_004)
        let registry = SnapshotCountingDeviceRegistry(outcome: .ok([
            RegistryDevice(
                deviceId: "test-mac",
                platform: "mac",
                displayName: "Test Mac",
                lastSeenAt: clock.now,
                instances: [
                    RegistryAppInstance(
                        tag: "stable",
                        routes: [legacy],
                        lastSeenAt: clock.now
                    ),
                ]
            ),
        ]))
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [legacy],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let before = try #require(await pairedStore.activeMac(stackUserID: "user-1", teamID: nil))
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(factory.attemptedKinds().isEmpty)
        #expect(!store.connectionRequiresReauth)
        #expect(store.hasKnownPairedMac)
        #expect(await registry.counts() == .init(list: 1, fresh: 0))
        let copy = [store.connectionError, store.connectionErrorGuidance]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        #expect(copy.contains("update cmux"))
        #expect(copy.contains("mac"))
        #expect(copy.contains("automatically"))
        let after = try #require(await pairedStore.activeMac(stackUserID: "user-1", teamID: nil))
        #expect(after.macDeviceID == before.macDeviceID)
        #expect(after.routes == before.routes)
        #expect(after.createdAt == before.createdAt)
        #expect(after.isActive)
    }

    @Test func emptyRegistrySnapshotDoesNotClaimTheMacNeedsAnUpdate() async throws {
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: KindRecordingTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox()
            ),
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try tailscale(51_010)],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: SnapshotCountingDeviceRegistry(outcome: .ok([])),
            runtime: runtime
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        let copy = [store.connectionError, store.connectionErrorGuidance]
            .compactMap { $0 }
            .joined(separator: " ")
        #expect(!copy.localizedCaseInsensitiveContains("update cmux"))
    }

    @Test func switchWithEmptyRegistrySnapshotDoesNotClaimTheMacNeedsAnUpdate() async throws {
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: KindRecordingTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox()
            ),
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try tailscale(51_011)],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: SnapshotCountingDeviceRegistry(outcome: .ok([])),
            runtime: runtime
        )

        #expect(!(await store.switchToMac(macDeviceID: "test-mac")))
        let copy = [store.connectionError, store.connectionErrorGuidance]
            .compactMap { $0 }
            .joined(separator: " ")
        #expect(!copy.localizedCaseInsensitiveContains("update cmux"))
    }

    @Test func activeIrohAuthorizationFailureOutranksSecondaryLegacyMigrationCopy() async throws {
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: AuthorizationRejectingTransportFactory(),
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let registry = SnapshotCountingDeviceRegistry(outcome: .ok([]))
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [try registryIroh(
                id: "iroh-a",
                endpointID: String(repeating: "a", count: 64)
            )],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Mac B",
            routes: [try tailscale(51_006)],
            instanceTag: "stable",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now.addingTimeInterval(1)
        )
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(store.connectionRequiresReauth)
        let copy = [store.connectionError, store.connectionErrorGuidance]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        #expect(!copy.contains("update cmux"))
    }

    @Test func switchingToIrohCapableMacUsesPinnedIrohRoute() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let store = try await makeReconnectStore(
            routes: [try tailscale(), try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(await store.switchToMac(macDeviceID: "test-mac"))
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(store.activeRoute?.kind == .iroh)
    }

    @Test func switchRejectsDisplayCacheRowRemovedFromAuthoritativeStore() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "test-mac", instanceTag: "stable")
        let factory = KindRecordingTransportFactory(router: router, box: TransportBox())
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try iroh()],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "iroh-store-authority-\(UUID().uuidString)"
            )!
        )
        await store.loadPairedMacs()
        #expect(store.pairedMacs.map(\.macDeviceID) == ["test-mac"])
        try await pairedStore.remove(
            macDeviceID: "test-mac",
            stackUserID: "user-1",
            teamID: nil
        )

        #expect(!(await store.switchToMac(macDeviceID: "test-mac")))
        #expect(factory.attemptedKinds().isEmpty)
    }

    @Test func foregroundResumeRedialsDeadIrohSessionBeforeUserAction() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = try await makeReconnectStore(
            routes: [try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(router: router, box: box),
                now: { clock.now },
                supportedRouteKinds: [.iroh]
            )
        )
        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        let firstTransport = try #require(box.get())
        await firstTransport.close()

        store.suspendForegroundRefresh()
        clock.advance(by: 61)
        store.resumeForegroundRefresh()

        let recovered = try await pollUntil(attempts: 100) {
            guard let current = box.get() else { return false }
            return current !== firstTransport
                && store.connectionState == .connected
        }
        #expect(recovered)
        #expect(store.activeRoute?.kind == .iroh)
    }

    @Test func subscribeStartFailureRedialsPinnedIrohWithoutRawFallback() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        await router.holdSubscribeRequest(number: 1)
        defer {
            Task { await router.releaseAllHeld() }
        }
        let store = try await makeReconnectStore(
            routes: [try tailscale(), try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        let firstTransport = try #require(box.get())
        let firstSubscribeStarted = try await pollUntil {
            await router.count(of: "mobile.events.subscribe") == 1
        }
        #expect(firstSubscribeStarted)

        // Model the Mac restarting while the first subscription handshake is
        // in flight. Recovery must discard this stale shell and authenticate a
        // fresh Iroh session to the same persisted Mac without trying the
        // secondary raw Tailscale route.
        await firstTransport.close()

        let recovered = try await pollUntil {
            guard let replacement = box.get() else { return false }
            let subscribeCount = await router.count(of: "mobile.events.subscribe")
            let workspaceListCount = await router.count(of: "workspace.list")
            return replacement !== firstTransport
                && store.connectionState == .connected
                && store.activeRoute?.kind == .iroh
                && subscribeCount >= 2
                && workspaceListCount >= 2
        }
        #expect(recovered)
        #expect(factory.attemptedKinds() == [.iroh, .iroh])
    }

    @Test func repeatedSubscribeStartFailureStopsAfterOneIrohRedial() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        await router.holdSubscribeRequest(number: 1)
        await router.holdSubscribeRequest(number: 2)
        defer {
            Task { await router.releaseAllHeld() }
        }
        let store = try await makeReconnectStore(
            routes: [try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh]
            )
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        let firstTransport = try #require(box.get())
        #expect(try await pollUntil {
            await router.count(of: "mobile.events.subscribe") == 1
        })
        await firstTransport.close()

        let replacementStarted = try await pollUntil {
            guard let replacement = box.get(), replacement !== firstTransport else {
                return false
            }
            return await router.count(of: "mobile.events.subscribe") == 2
        }
        #expect(replacementStarted)
        let replacement = try #require(box.get())
        await replacement.close()

        let stopped = try await pollUntil {
            store.connectionState == .disconnected
                && store.connectionRecoveryFailed
        }
        #expect(stopped)
        #expect(factory.attemptedKinds() == [.iroh, .iroh])
    }

    @Test func storedReconnectPinsIrohAndExcludesRawFallbacks() throws {
        let routes = MobileShellComposite.storedReconnectRoutes(
            [try loopback(), try tailscale(), try iroh()],
            supportedKinds: [.iroh, .tailscale, .debugLoopback],
            preferNonLoopback: true
        )

        #expect(routes.map(\.kind) == [.iroh])
        guard case let .peer(identity, hints) = routes[0].endpoint else {
            Issue.record("Expected pinned Iroh route")
            return
        }
        #expect(identity.endpointID == String(repeating: "a", count: 64))
        #expect(hints.count == 1)
        #expect(hints[0].value == "100.82.214.112:50906")
        #expect(hints[0].source == .tailscale)
        #expect(hints[0].use == .fallbackOnly)
    }

    private func registryIroh(id: String, endpointID: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: endpointID),
                pathHints: []
            ),
            priority: -10_000
        )
    }

    private func seedVersionSevenPairing(
        at databaseURL: URL,
        route: CmxAttachRoute,
        stackUserID: String
    ) throws {
        let ownerKey = "\(stackUserID)\u{1F}\u{1F}"
        let routeData = try JSONEncoder().encode(route)
        let routeJSON = try #require(String(data: routeData, encoding: .utf8))
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let seed = """
            CREATE TABLE paired_macs (
                mac_device_id TEXT NOT NULL,
                owner_key TEXT NOT NULL,
                display_name TEXT,
                stack_user_id TEXT,
                team_id TEXT,
                created_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 0,
                custom_name TEXT,
                custom_color TEXT,
                custom_icon TEXT,
                instance_tag TEXT,
                PRIMARY KEY (mac_device_id, owner_key)
            );
            CREATE TABLE mac_routes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mac_device_id TEXT NOT NULL,
                owner_key TEXT NOT NULL,
                route_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                endpoint_json TEXT NOT NULL,
                priority INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (mac_device_id, owner_key)
                    REFERENCES paired_macs(mac_device_id, owner_key)
                    ON DELETE CASCADE
            );
            INSERT INTO paired_macs VALUES (
                'test-mac', \(sqlQuoted(ownerKey)), 'Test Mac',
                \(sqlQuoted(stackUserID)), NULL, 0, 0, 1,
                NULL, NULL, NULL, NULL
            );
            INSERT INTO mac_routes (
                mac_device_id, owner_key, route_id, kind, endpoint_json, priority
            ) VALUES (
                'test-mac', \(sqlQuoted(ownerKey)), \(sqlQuoted(route.id)),
                'tailscale', \(sqlQuoted(routeJSON)), \(route.priority)
            );
            PRAGMA user_version = 7;
        """
        #expect(sqlite3_exec(database, seed, nil, nil, nil) == SQLITE_OK)
    }

    private func sqlQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func makeMigrationShell(
        pairedStore: any MobilePairedMacStoring,
        registry: any DeviceRegistryRefreshing,
        runtime: any MobileSyncRuntime
    ) async -> MobileShellComposite {
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "iroh-migration-\(UUID().uuidString)")!
        )
        await store.loadPairedMacs()
        return store
    }
}

private actor SnapshotCountingDeviceRegistry: DeviceRegistryRefreshing {
    struct Counts: Equatable, Sendable {
        let list: Int
        let fresh: Int
    }

    private let outcome: DeviceRegistryListOutcome
    private var listCalls = 0
    private var freshCalls = 0

    init(outcome: DeviceRegistryListOutcome) {
        self.outcome = outcome
    }

    func freshRoutes(
        forMacDeviceID _: String,
        instanceTag _: String?
    ) async -> [CmxAttachRoute]? {
        freshCalls += 1
        return nil
    }

    func listDevices() async -> DeviceRegistryListOutcome {
        listCalls += 1
        return outcome
    }

    func counts() -> Counts {
        Counts(list: listCalls, fresh: freshCalls)
    }
}

private actor PresenceRacingDeviceRegistry: DeviceRegistryRefreshing {
    struct State: Equatable, Sendable {
        let listCalls: Int
        let wrotePresenceRoutes: Bool
    }

    private let pairedStore: MobilePairedMacStore
    private let routes: [CmxAttachRoute]
    private let outcome: DeviceRegistryListOutcome
    private let now: Date
    private var listCalls = 0
    private var wrotePresenceRoutes = false

    init(
        pairedStore: MobilePairedMacStore,
        routes: [CmxAttachRoute],
        outcome: DeviceRegistryListOutcome,
        now: Date
    ) {
        self.pairedStore = pairedStore
        self.routes = routes
        self.outcome = outcome
        self.now = now
    }

    func freshRoutes(
        forMacDeviceID _: String,
        instanceTag _: String?
    ) async -> [CmxAttachRoute]? {
        nil
    }

    func listDevices() async -> DeviceRegistryListOutcome {
        listCalls += 1
        do {
            wrotePresenceRoutes = try await pairedStore.upsertRoutesIfAuthorized(
                macDeviceID: "test-mac",
                displayName: "Test Mac",
                routes: routes,
                condition: .matchingInstanceTag("stable"),
                markActive: nil,
                stackUserID: "user-1",
                teamID: nil,
                now: now
            )
            return outcome
        } catch {
            return .transientFailure
        }
    }

    func state() -> State {
        State(listCalls: listCalls, wrotePresenceRoutes: wrotePresenceRoutes)
    }
}

private struct AuthorizationRejectingTransportFactory: CmxByteTransportFactory {
    func makeTransport(for _: CmxAttachRoute) throws -> any CmxByteTransport {
        throw MobileShellConnectionError.authorizationFailed("authorization rejected")
    }
}
