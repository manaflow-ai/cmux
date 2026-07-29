import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
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
        shell.commitFocusedConnectionHandoff(
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

        shell.adoptPooledRemoteClient(newClient)

        #expect(shell.remoteClient === newClient)
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

        shell.installControlConnection(from: stale)
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

        shell.connectionGeneration = UUID()
        shell.invalidateFocusedConnectionAfterAbortedHandoff(current)

        #expect(shell.connections["mac-a"] == nil)
        #expect(shell.remoteClient == nil)
        #expect(shell.foregroundMacDeviceID == nil)
        #expect(shell.connectionState == .disconnected)
        await client.disconnect()
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
            supportedHostCapabilities: [],
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
            "Recreated Catch-up",
        ])
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

        await router.dropSubscription()
        clock.advance(by: .seconds(20))

        #expect(await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 2
        ))
        #expect(try await pollUntil {
            let feedFetchCount = await router.count(
                of: "notification.feed.list"
            )
            return shell.workspacesByMac["mac-b"]?.workspaces.first?.name
                == "Recreated Catch-up"
                && feedFetchCount > feedFetchesBeforeGap
        })
        #expect(shell.secondaryMacSubscriptions["mac-b"] === subscription)

        subscription.cancel()
        shell.secondaryMacSubscriptions["mac-b"] = nil
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
            supportedHostCapabilities: [],
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
                supportedHostCapabilities: [],
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
            connectionState: .connected
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
        shell.secondaryMacSubscriptions["mac-b"] = SecondaryMacSubscription(
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

        await router.releaseAllHeld()
        _ = try await connectTask.value

        #expect(shell.foregroundMacDeviceID == "mac-b")
        #expect(shell.activeTicket?.macDeviceID == "mac-b")
        #expect(shell.activeRoute == targetRoute)
        #expect(shell.connectedHostName == "Mac B")
        #expect(shell.selectedWorkspace?.macDeviceID == "mac-b")
        #expect(shell.selectedWorkspace?.rpcWorkspaceID.rawValue == "live-workspace")
        #expect(shell.secondaryMacSubscriptions["mac-b"] == nil)
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
