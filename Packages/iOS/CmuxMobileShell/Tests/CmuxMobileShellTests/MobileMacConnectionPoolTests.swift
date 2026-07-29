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
        #expect(SecondaryMacSubscription.eventTopics.contains("mobile.sync.delta"))
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

        await shell.relinquishFocusedConnection(
            connection,
            retainAsControl: true
        )

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
        #expect(shell.connections["mac-a"] == nil)
        #expect(shell.secondaryMacSubscriptions["mac-a"]?.client
            === previousClient)
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

        await shell.refreshSecondaryMacWorkspaces()

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
