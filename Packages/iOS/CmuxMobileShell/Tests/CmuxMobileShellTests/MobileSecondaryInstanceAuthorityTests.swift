import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileSecondaryInstanceAuthorityTests {
    @Test func promotionStoreFailurePreservesWarmControlConnection()
        async throws {
        let route = try CmxAttachRoute(
            id: "promotion-store-failure",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let pairedMac = MobilePairedMac(
            macDeviceID: "mac-b",
            displayName: "Studio B",
            routes: [route],
            createdAt: .distantPast,
            lastSeenAt: Date(),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            instanceTag: "feature-b"
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [pairedMac]],
            blockedTeams: []
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
            teamIDProvider: { "team-a" },
            reachability: AlwaysOnlineReachability(),
            controlPlaneSchedulingClock: clock
        )
        shell.workspacesByMac[MacPairingKey(pairedMac)] = MacWorkspaceState(
            macDeviceID: pairedMac.macDeviceID,
            displayName: pairedMac.displayName,
            status: .connected
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
        let switchAttemptID = UUID()
        shell.macSwitchAttemptID = switchAttemptID
        shell.macSwitchAttemptSignInGeneration = shell.signInGeneration
        await pairedStore.failNextLoadAll()

        let outcome = await shell.promoteSecondaryToForegroundOutcome(
            MacPairingKey(pairedMac),
            switchAttemptID: switchAttemptID
        )

        guard case .transientFailure = outcome else {
            Issue.record("expected transient promotion failure")
            return
        }
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

    @Test func promotionTransfersAuthenticatedTagFromSecondaryClient() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "secondary-b",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Studio B",
            routes: [route],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date()
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-a",
            displayName: "Studio A",
            routes: [route],
            instanceTag: "feature-a",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date()
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: nil,
            instanceTag: nil,
            displayName: nil
        )
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { Date() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "mac-b",
            macDisplayName: "Studio B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let foregroundTicket = try CmxAttachTicket(
            workspaceID: "foreground-workspace",
            terminalID: "foreground-terminal",
            macDeviceID: "mac-a",
            macDisplayName: "Studio A",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let foregroundClient = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: foregroundTicket,
            allowsStackAuthFallback: true
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "secondary-authority-\(UUID().uuidString)"
            )!
        )
        shell.foregroundMacDeviceID = "mac-a"
        shell.activeMacInstanceTag = "feature-a"
        shell.activeTicket = foregroundTicket
        shell.activeRoute = route
        shell.connectedHostName = "Studio A"
        shell.remoteClient = foregroundClient
        shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "feature-a")] = MacConnection(
            macDeviceID: "mac-a",
            ticket: foregroundTicket,
            route: route,
            client: foregroundClient,
            generation: UUID(),
            displayName: "Studio A",
            instanceTag: "feature-a",
            supportedHostCapabilities: ["terminal.render_grid.v1"],
            actionCapabilities: .none
        )
        shell.secondaryMacSubscriptions["mac-b".pairingKey] = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: nil,
            authenticatedInstanceTag: "feature-b",
            supportedHostCapabilities: ["terminal.render_grid.v1"],
            actionCapabilities: .none
        )

        let switchAttemptID = UUID()
        shell.macSwitchAttemptID = switchAttemptID
        shell.macSwitchAttemptSignInGeneration = shell.signInGeneration

        #expect(await shell.promoteSecondaryToForeground("mac-b".pairingKey,
            switchAttemptID: switchAttemptID
        ))
        #expect(shell.activeMacInstanceTag == "feature-b")
        #expect(shell.foregroundMacDeviceID == "mac-b")
        #expect(shell.connectionState == .connected)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-a", instanceTag: "feature-a")]?.client === foregroundClient)
        #expect(shell.liveMacConnections.map(\.macDeviceID) == ["mac-b", "mac-a"])
        #expect(shell.liveMacConnections.map(\.role) == [.focused, .control])
        let promotedConnection = try #require(shell.connections["mac-b"])
        #expect(promotedConnection.storedInstanceTag == nil)
        #expect(promotedConnection.authenticatedInstanceTag == "feature-b")
        #expect(await shell.canRetainFocusedConnectionInControlPool(
            promotedConnection
        ))
        #expect(try await pollUntil {
            do {
                let active = try await pairedStore.activeMac(
                    stackUserID: "user-1",
                    teamID: "team-a"
                )
                return active?.macDeviceID == "mac-b"
            } catch {
                return false
            }
        })
        let persistedActiveMac = try #require(
            try await pairedStore.activeMac(
                stackUserID: "user-1",
                teamID: "team-a"
            )
        )
        #expect(persistedActiveMac.instanceTag == nil)
        let foregroundStillWarm = try? await foregroundClient.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.host.status",
                params: [:]
            )
        )
        #expect(foregroundStillWarm != nil)
    }

    @Test func freshDialDrainTimeoutDoesNotReportOldFocusAsSuccess()
        async throws {
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "mac-b",
            instanceTag: "feature-b",
            displayName: "Studio B"
        )
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
            id: "fresh-dial-drain-timeout",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let foregroundRoute = try CmxAttachRoute(
            id: "fresh-dial-drain-foreground",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_583)
        )
        let targetTicket = try CmxAttachTicket(
            workspaceID: "target-workspace",
            terminalID: "target-terminal",
            macDeviceID: "mac-b",
            macDisplayName: "Studio B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let targetClient = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: targetTicket,
            allowsStackAuthFallback: true
        )
        _ = try await targetClient.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.host.status",
                params: [:]
            )
        )
        let foregroundTicket = try CmxAttachTicket(
            workspaceID: "foreground-workspace",
            terminalID: "foreground-terminal",
            macDeviceID: "mac-a",
            macDisplayName: "Studio A",
            routes: [foregroundRoute],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let foregroundClient = MobileCoreRPCClient(
            runtime: runtime,
            route: foregroundRoute,
            ticket: foregroundTicket,
            allowsStackAuthFallback: true
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            connectionHandoffDrainTimeoutNanoseconds: 1_000_000
        )
        shell.foregroundMacDeviceID = "mac-a"
        shell.activeTicket = foregroundTicket
        shell.activeRoute = foregroundRoute
        shell.connectedHostName = "Studio A"
        shell.remoteClient = foregroundClient
        shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "feature-a")] = MacConnection(
            macDeviceID: "mac-a",
            ticket: foregroundTicket,
            route: foregroundRoute,
            client: foregroundClient,
            generation: UUID(),
            displayName: "Studio A",
            instanceTag: "feature-a",
            supportedHostCapabilities: ["terminal.render_grid.v1"],
            actionCapabilities: .none
        )
        let targetSubscription = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: targetClient,
            route: route,
            ticket: targetTicket,
            storedInstanceTag: "feature-b",
            authenticatedInstanceTag: "feature-b",
            supportedHostCapabilities: ["terminal.render_grid.v1"],
            actionCapabilities: .none,
            displayName: "Studio B"
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] = targetSubscription

        do {
            _ = try await shell.connect(
                ticket: targetTicket,
                pairedMacDeviceID: "mac-b"
            )
            Issue.record("Expected the timed-out target drain to fail")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await closeGate.waitUntilCloseStarted())

        #expect(shell.connectionState == .connected)
        #expect(shell.foregroundMacDeviceID == "mac-a")
        #expect(shell.activeTicket?.macDeviceID == "mac-a")
        #expect(shell.remoteClient === foregroundClient)
        #expect(shell.secondaryMacDrainReservations[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")]
            === targetSubscription)

        await closeGate.release()
        #expect(try await pollUntil {
            shell.secondaryMacDrainReservations[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] == nil
        })
        await foregroundClient.disconnect()
    }

    @Test(arguments: [
        PromotionFocusRepairFailure.hostIdentity,
        .terminalSubscription,
        .workspaceRefresh,
    ])
    func promotionFailsClosedWhenRequiredFocusRepairFails(
        failure: PromotionFocusRepairFailure
    ) async throws {
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
            id: "promotion-subscribe-failure",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Studio B",
            routes: [route],
            instanceTag: "feature-b",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date()
        )
        let router = LivenessHostRouter()
        let closeGate = LivenessTransportCloseGate()
        if failure != .hostIdentity {
            await router.setHostIdentity(
                deviceID: "mac-b",
                instanceTag: "feature-b"
            )
        }
        if failure == .terminalSubscription {
            await router.invalidateSubscribeRequest(number: 1)
        } else if failure == .workspaceRefresh {
            await router.failWorkspaceListRequest(number: 2)
        }
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox(),
                closeGate: closeGate
            ),
            now: { Date() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "mac-b",
            macDisplayName: "Studio B",
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
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            reachability: AlwaysOnlineReachability(),
            connectionHandoffDrainTimeoutNanoseconds: 1_000_000
        )
        shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] = MacWorkspaceState(
            macDeviceID: "mac-b",
            displayName: "Studio B",
            workspaces: [
                MobileWorkspacePreview(
                    id: .init(rawValue: "live-workspace"),
                    macDeviceID: "mac-b",
                    name: "Target Workspace",
                    terminals: [
                        MobileTerminalPreview(
                            id: .init(rawValue: "live-terminal"),
                            name: "Terminal",
                            isReady: true
                        ),
                    ]
                ),
            ],
            status: .connected
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "feature-b",
            authenticatedInstanceTag: "feature-b",
            supportedHostCapabilities: ["terminal.render_grid.v1"],
            actionCapabilities: .none,
            displayName: "Studio B"
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] = subscription
        let switchAttemptID = UUID()
        shell.macSwitchAttemptID = switchAttemptID
        shell.macSwitchAttemptSignInGeneration = shell.signInGeneration

        let promoted = await shell.promoteSecondaryToForeground(MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b"),
            switchAttemptID: switchAttemptID
        )

        #expect(!promoted)
        #expect(shell.connectionState == .disconnected)
        #expect(shell.remoteClient == nil)
        #expect(shell.foregroundMacDeviceID == nil)
        #expect(!shell.isRecoveringConnection)
        #expect(!shell.liveMacConnections.contains {
            $0.macDeviceID == "mac-b"
        })
        #expect(await closeGate.waitUntilCloseStarted())
        #expect(shell.secondaryMacDrainReservations[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")]
            === subscription)
        shell.finishMacSwitchAttempt(switchAttemptID)
        await closeGate.release()
        #expect(try await pollUntil {
            shell.secondaryMacDrainReservations[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] == nil
        })
        await client.disconnect()
    }

    @Test func failedControlUnsubscribeRetiresPromotionClientBeforeFallback()
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
            id: "promotion-unsubscribe-failure",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Studio B",
            routes: [route],
            instanceTag: "feature-b",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date()
        )
        let router = LivenessHostRouter()
        await router.invalidateUnsubscribeRequest(number: 1)
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
            macDeviceID: "mac-b",
            macDisplayName: "Studio B",
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
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            reachability: AlwaysOnlineReachability()
        )
        shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] = MacWorkspaceState(
            macDeviceID: "mac-b",
            displayName: "Studio B",
            workspaces: [
                MobileWorkspacePreview(
                    id: .init(rawValue: "live-workspace"),
                    macDeviceID: "mac-b",
                    name: "Target Workspace",
                    terminals: []
                ),
            ],
            status: .connected
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "feature-b",
            authenticatedInstanceTag: "feature-b",
            supportedHostCapabilities: [
                "events.v1",
                "terminal.render_grid.v1",
            ],
            actionCapabilities: .none,
            displayName: "Studio B"
        )
        let switchAttemptID = UUID()
        shell.macSwitchAttemptID = switchAttemptID
        shell.macSwitchAttemptSignInGeneration = shell.signInGeneration

        let promoted = await shell.promoteSecondaryToForeground(MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b"),
            switchAttemptID: switchAttemptID
        )

        #expect(!promoted)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] == nil)
        #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")]?.status == .unavailable)
        do {
            _ = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "mobile.host.status",
                    params: [:]
                )
            )
            Issue.record("retired promotion client accepted a new request")
        } catch let error as MobileShellConnectionError {
            guard case .connectionClosed = error else {
                Issue.record("expected connectionClosed, got \(error)")
                return
            }
        }
    }

    @Test func timedOutPromotionDrainIsNotPublishedOrActionable()
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
            id: "promotion-drain-reservation",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "mac-b",
            macDisplayName: "Studio B",
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
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionHandoffDrainTimeoutNanoseconds: 1_000_000
        )
        let subscription = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "feature-b",
            authenticatedInstanceTag: "feature-b",
            supportedHostCapabilities: ["notification.feed.v1"],
            actionCapabilities: .none,
            displayName: "Studio B"
        )
        let workspaceID = MobileWorkspacePreview.ID(
            rawValue: "live-workspace"
        )
        shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] = MacWorkspaceState(
            macDeviceID: "mac-b",
            displayName: "Studio B",
            workspaces: [
                MobileWorkspacePreview(
                    id: workspaceID,
                    macDeviceID: "mac-b",
                    name: "Target Workspace",
                    terminals: []
                ),
            ],
            status: .connected
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] = subscription

        await shell.retireSecondaryPromotionCandidate(subscription)
        #expect(await closeGate.waitUntilCloseStarted())

        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] == nil)
        #expect(shell.secondaryMacDrainReservations[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")]
            === subscription)
        #expect(!shell.liveMacConnections.contains {
            $0.macDeviceID == "mac-b"
        })
        #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")]?.status == .unavailable)
        #expect(shell.workspaceMutationTarget(for: workspaceID).client == nil)

        await closeGate.release()
        #expect(try await pollUntil {
            shell.secondaryMacDrainReservations[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] == nil
        })
        await client.disconnect()
    }

    @Test(arguments: PromotionWorkspaceRace.allCases)
    func promotionDoesNotOverwriteNewerForegroundWorkspaceState(
        race: PromotionWorkspaceRace
    ) async throws {
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
            id: "promotion-freshness",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Studio B",
            routes: [route],
            instanceTag: "feature-b",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date()
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-a",
            displayName: "Studio A",
            routes: [route],
            instanceTag: "feature-a",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date()
        )
        let targetRouter = LivenessHostRouter()
        await targetRouter.setHostIdentity(
            deviceID: "mac-b",
            instanceTag: "feature-b",
            displayName: "Studio B"
        )
        await targetRouter.scriptWorkspaceListTitles([
            "Preflight Snapshot",
            "Stale Promotion Snapshot",
            "Event Fresh Snapshot",
        ])
        await targetRouter.holdWorkspaceListRequest(number: 2)
        let targetTransportBox = TransportBox()
        let targetRuntime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: targetRouter,
                box: targetTransportBox
            ),
            now: { Date() }
        )
        let oldRouter = LivenessHostRouter()
        await oldRouter.holdUnsubscribeRequest(number: 1)
        let oldRuntime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: oldRouter,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let targetTicket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "mac-b",
            macDisplayName: "Studio B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let oldTicket = try CmxAttachTicket(
            workspaceID: "old-workspace",
            terminalID: "old-terminal",
            macDeviceID: "mac-a",
            macDisplayName: "Studio A",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let targetClient = MobileCoreRPCClient(
            runtime: targetRuntime,
            route: route,
            ticket: targetTicket,
            allowsStackAuthFallback: true
        )
        let oldClient = MobileCoreRPCClient(
            runtime: oldRuntime,
            route: route,
            ticket: oldTicket,
            allowsStackAuthFallback: true
        )
        let shell = MobileShellComposite(
            runtime: targetRuntime,
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            presence: SecondaryAuthorityIdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            reachability: AlwaysOnlineReachability()
        )
        shell.remoteClient = oldClient
        shell.activeTicket = oldTicket
        shell.activeRoute = route
        shell.activeMacInstanceTag = "feature-a"
        shell.foregroundMacDeviceID = "mac-a"
        shell.connections[MacPairingKey(macDeviceID: "mac-a", instanceTag: "feature-a")] = MacConnection(
            macDeviceID: "mac-a",
            ticket: oldTicket,
            route: route,
            client: oldClient,
            generation: shell.connectionGeneration,
            displayName: "Studio A",
            instanceTag: "feature-a",
            supportedHostCapabilities: ["terminal.render_grid.v1"],
            actionCapabilities: .none
        )
        shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-a", instanceTag: "feature-a")] = MacWorkspaceState(
            macDeviceID: "mac-a",
            displayName: "Studio A",
            workspaces: [
                MobileWorkspacePreview(
                    id: .init(rawValue: "old-workspace"),
                    macDeviceID: "mac-a",
                    name: "Old Workspace",
                    terminals: []
                ),
            ],
            status: .connected
        )
        shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] = MacWorkspaceState(
            macDeviceID: "mac-b",
            displayName: "Studio B",
            workspaces: [
                MobileWorkspacePreview(
                    id: .init(rawValue: "live-workspace"),
                    macDeviceID: "mac-b",
                    name: "Control Snapshot",
                    terminals: []
                ),
            ],
            status: .connected
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: targetClient,
            route: route,
            ticket: targetTicket,
            storedInstanceTag: "feature-b",
            authenticatedInstanceTag: "feature-b",
            supportedHostCapabilities: ["terminal.render_grid.v1"],
            actionCapabilities: .none
        )
        shell.applyPresenceUpdate(
            secondaryAuthorityPresenceSnapshot(macAOnline: true),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-a",
                generation: 0
            )
        )

        let switchTask: Task<Bool, Never>
        if race == .eventRefreshFailure {
            let switchAttemptID = UUID()
            shell.macSwitchAttemptID = switchAttemptID
            shell.macSwitchAttemptSignInGeneration = shell.signInGeneration
            switchTask = Task { @MainActor in
                await shell.promoteSecondaryToForeground(MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b"),
                    switchAttemptID: switchAttemptID
                )
            }
        } else {
            switchTask = Task { @MainActor in
                await shell.switchToMac(
                    macDeviceID: "mac-b",
                    instanceTag: "feature-b"
                )
            }
        }
        #expect(await oldRouter.waitForCount(
            of: "mobile.events.unsubscribe",
            atLeast: 1
        ))
        #expect(try await pollUntil {
            await oldRouter.heldRequestCount() == 1
        })
        shell.applyPresenceUpdate(
            secondaryAuthorityPresenceSnapshot(macAOnline: false),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-a",
                generation: 0
            )
        )
        await oldRouter.releaseAllHeld()
        #expect(await targetRouter.waitForCount(
            of: "workspace.list",
            atLeast: 2
        ))
        #expect(try await pollUntil {
            await targetRouter.heldRequestCount() == 1
        })
        #expect(shell.foregroundMacDeviceID == "mac-b")
        #expect(shell.selectedWorkspace?.macDeviceID == "mac-b")
        #expect(shell.selectedWorkspace?.rpcWorkspaceID.rawValue
            == "live-workspace")
        if race != .eventRefreshFailure {
            #expect(shell.macSwitchRestoreBaseline?.macDeviceID == "mac-a")
        }
        let expectedFreshTitle: String
        if race == .stateSyncProjection {
            expectedFreshTitle = "State Sync Fresh Snapshot"
            shell.applyRemoteWorkspaceList(
                MobileSyncWorkspaceListResponse(
                    workspaces: [
                        .init(
                            id: "live-workspace",
                            windowID: nil,
                            title: expectedFreshTitle,
                            currentDirectory: nil,
                            isSelected: true,
                            isPinned: nil,
                            groupID: nil,
                            preview: nil,
                            previewAt: nil,
                            lastActivityAt: nil,
                            hasUnread: nil,
                            terminals: []
                        ),
                    ],
                    groups: [],
                    createdWorkspaceID: nil,
                    createdTerminalID: nil
                )
            )
        } else {
            expectedFreshTitle = "Event Fresh Snapshot"
            if race == .eventRefreshFailure {
                await targetRouter.failWorkspaceListRequest(number: 3)
            }
            let targetTransport = try #require(targetTransportBox.get())
            await targetTransport.deliver(
                try promotionWorkspaceUpdatedEventFrame()
            )
            #expect(await targetRouter.waitForCount(
                of: "mobile.workspace.list",
                atLeast: 1
            ))
        }

        await targetRouter.releaseAllHeld()
        let switched = await switchTask.value
        if race == .eventRefreshFailure {
            #expect(!switched)
            #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")]?.workspaces.first?.name
                != "Stale Promotion Snapshot")
            await targetClient.disconnect()
            return
        }
        #expect(switched)
        #expect(try await pollUntil {
            shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")]?.workspaces.first?.name
                == expectedFreshTitle
        })
        #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")]?.workspaces.first?.name
            != "Stale Promotion Snapshot")
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-a", instanceTag: "feature-a")] == nil)
        #expect(!shell.liveMacConnections.contains {
            $0.macDeviceID == "mac-a"
        })
        await targetClient.disconnect()
    }

    @Test func promotionRetiresAnonymousUnregisteredForegroundClient() async throws {
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
            id: "anonymous-promotion",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Studio B",
            routes: [route],
            instanceTag: "feature-b",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date()
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "mac-b",
            instanceTag: "feature-b",
            displayName: "Studio B"
        )
        let anonymousTransportBox = TransportBox()
        let anonymousRuntime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: anonymousTransportBox
            ),
            now: { Date() }
        )
        let targetRuntime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() }
        )
        let anonymousTicket = try CmxAttachTicket(
            workspaceID: "anonymous-workspace",
            terminalID: "anonymous-terminal",
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let targetTicket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "mac-b",
            macDisplayName: "Studio B",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let anonymousClient = MobileCoreRPCClient(
            runtime: anonymousRuntime,
            route: route,
            ticket: anonymousTicket,
            allowsStackAuthFallback: true
        )
        let targetClient = MobileCoreRPCClient(
            runtime: targetRuntime,
            route: route,
            ticket: targetTicket,
            allowsStackAuthFallback: true
        )
        _ = try await anonymousClient.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.host.status",
                params: [:]
            )
        )
        let anonymousTransport = try #require(anonymousTransportBox.get())
        let shell = MobileShellComposite(
            runtime: targetRuntime,
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            reachability: AlwaysOnlineReachability()
        )
        shell.remoteClient = anonymousClient
        shell.activeTicket = anonymousTicket
        shell.activeRoute = route
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-b")] = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: targetClient,
            route: route,
            ticket: targetTicket,
            storedInstanceTag: "feature-b",
            authenticatedInstanceTag: "feature-b",
            supportedHostCapabilities: ["terminal.render_grid.v1"],
            actionCapabilities: .none
        )

        #expect(await shell.switchToMac(
            macDeviceID: "mac-b",
            instanceTag: "feature-b"
        ))
        #expect(shell.remoteClient === targetClient)
        #expect(shell.foregroundMacDeviceID == "mac-b")
        var anonymousTransportClosed = await anonymousTransport.isClosedForTesting()
        for _ in 0..<50 where !anonymousTransportClosed {
            try? await Task.sleep(for: .milliseconds(10))
            anonymousTransportClosed = await anonymousTransport.isClosedForTesting()
        }
        #expect(anonymousTransportClosed)
        await targetClient.disconnect()
    }

    @Test func promotionRejectsAWhenStoreChangesToBDuringWorkspaceProbe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "secondary-shared",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Studio",
            routes: [route],
            instanceTag: "feature-a",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "mac-b", instanceTag: "feature-a", displayName: "Studio"
        )
        await router.holdWorkspaceListRequest(number: 1)
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router, box: TransportBox()
            ),
            now: { Date() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "mac-b",
            macDisplayName: "Studio",
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
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "secondary-authority-race-\(UUID().uuidString)"
            )!
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-a")] = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "feature-a",
            authenticatedInstanceTag: "feature-a",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )

        let switchTask = Task { @MainActor in
            await shell.switchToMac(macDeviceID: "mac-b")
        }
        #expect(await router.waitForCount(of: "workspace.list", atLeast: 1))
        try await pairedStore.remove(
            macDeviceID: "mac-b",
            instanceTag: "feature-a",
            stackUserID: "user-1",
            teamID: "team-a"
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Studio",
            routes: [route],
            instanceTag: "feature-b",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        )
        await router.releaseAllHeld()

        let switched = await switchTask.value
        #expect(!switched)
        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-a")] == nil)
        #expect(shell.foregroundMacDeviceID != "mac-b")
        #expect(shell.activeMacInstanceTag != "feature-a")
    }

    @Test func reseedRejectsAWhenStoreChangesToBDuringWorkspaceFetch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "secondary-shared",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Studio",
            routes: [route],
            instanceTag: "feature-a",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        let router = LivenessHostRouter()
        await router.holdWorkspaceListRequest(number: 1)
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router, box: TransportBox()
            ),
            now: { Date() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "mac-b",
            macDisplayName: "Studio",
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
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "secondary-reseed-authority-\(UUID().uuidString)"
            )!
        )
        shell.foregroundMacDeviceID = "mac-a"
        shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-a")] = MacWorkspaceState(
            macDeviceID: "mac-b",
            displayName: "Studio",
            status: .connected
        )
        shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-a")] = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "feature-a",
            authenticatedInstanceTag: "feature-a",
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )

        let refreshTask = Task { @MainActor in
            await shell.refreshSecondaryMacWorkspaces()
        }
        #expect(await router.waitForCount(of: "workspace.list", atLeast: 1))
        try await pairedStore.remove(
            macDeviceID: "mac-b",
            instanceTag: "feature-a",
            stackUserID: "user-1",
            teamID: "team-a"
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Studio",
            routes: [route],
            instanceTag: "feature-b",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        )
        await router.releaseAllHeld()
        await refreshTask.value

        #expect(shell.secondaryMacSubscriptions[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-a")] == nil)
        #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-a")]?.status == .unavailable)
        #expect(shell.workspacesByMac[MacPairingKey(macDeviceID: "mac-b", instanceTag: "feature-a")]?.workspaces.isEmpty == true)
    }
}

private func promotionWorkspaceUpdatedEventFrame() throws -> Data {
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "workspace.updated",
        "payload": [String: Any](),
    ]
    return try MobileSyncFrameCodec.encodeFrame(
        JSONSerialization.data(withJSONObject: envelope)
    )
}

private func secondaryAuthorityPresenceSnapshot(
    macAOnline: Bool
) -> PresenceUpdate {
    func instance(
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
    let instances = [
        instance(
            deviceID: "mac-a",
            tag: "feature-a",
            online: macAOnline
        ),
        instance(
            deviceID: "mac-b",
            tag: "feature-b",
            online: true
        ),
    ]
    let devices = Dictionary(grouping: instances, by: \.deviceId)
        .map { deviceID, deviceInstances in
            PresenceDevice(
                deviceId: deviceID,
                platform: "mac",
                displayName: deviceID,
                online: deviceInstances.contains(where: \.online),
                lastSeenAt: 1_000,
                instances: deviceInstances
            )
        }
    return .snapshot(PresenceSnapshot(
        teamId: "team-a",
        now: 1_000,
        heartbeatIntervalMs: 15_000,
        offlineTimeoutMs: 45_000,
        devices: devices
    ))
}
