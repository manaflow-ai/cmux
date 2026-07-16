import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileSecondaryInstanceAuthorityTests {
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
            instanceTag: "feature-b",
            markActive: false,
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
        shell.secondaryMacSubscriptions["mac-b"] = SecondaryMacSubscription(
            macDeviceID: "mac-b",
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: "feature-b",
            authenticatedInstanceTag: "feature-b",
            supportedHostCapabilities: ["terminal.render_grid.v1"],
            actionCapabilities: .none
        )

        #expect(await shell.switchToMac(macDeviceID: "mac-b"))
        #expect(shell.activeMacInstanceTag == "feature-b")
        #expect(shell.foregroundMacDeviceID == "mac-b")
        let statusResolved = await router.waitForCount(
            of: "mobile.host.status",
            atLeast: 1,
            recordIssueOnTimeout: false
        )
        #expect(statusResolved)
        #expect(shell.connectionState == .connected)
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
        shell.secondaryMacSubscriptions["mac-b"] = SecondaryMacSubscription(
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
        #expect(shell.secondaryMacSubscriptions["mac-b"] == nil)
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
        shell.workspacesByMac["mac-b"] = MacWorkspaceState(
            macDeviceID: "mac-b",
            displayName: "Studio",
            status: .connected
        )
        shell.secondaryMacSubscriptions["mac-b"] = SecondaryMacSubscription(
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

        #expect(shell.secondaryMacSubscriptions["mac-b"] == nil)
        #expect(shell.workspacesByMac["mac-b"]?.status == .unavailable)
        #expect(shell.workspacesByMac["mac-b"]?.workspaces.isEmpty == true)
    }

    @Test func promotionRejectsSnapshotOlderThanSecondaryRefreshGeneration() async throws {
        let router = RoutingHostRouter()
        await router.workspaceListGate.setUsesOrdinalTitles(true)
        let macID = "secondary-promotion-generation"
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [promotionPairedMac(macID: macID)]],
            blockedTeams: []
        )
        await pairedStore.gateLoadAll(number: 2)
        let shell = makeRoutingMultiMacStore(router: router, pairedMacStore: pairedStore)
        try installSecondaryClient(on: shell, macDeviceID: macID, router: router)
        let subscription = try #require(shell.secondaryMacSubscriptions[macID])

        let switchTask = Task { @MainActor in
            await shell.switchToMac(macDeviceID: macID)
        }
        // Promotion has decoded its first workspace list and is suspended in its
        // post-fetch paired-Mac authority read.
        await pairedStore.waitUntilLoadAllStarted(number: 2)

        let newerRefresh = try #require(shell.scheduleSecondaryRefresh(
            macID: macID,
            client: subscription.client,
            displayName: "Secondary Mac"
        ))
        await newerRefresh.value
        #expect(subscription.refreshCompletedGeneration == 1)
        #expect(shell.workspacesByMac[macID]?.workspaces.first?.name == "Fresh Workspace")

        await pairedStore.releaseLoadAll(number: 2)
        let switched = await switchTask.value

        #expect(!switched)
        #expect(shell.foregroundMacDeviceID != macID)
        #expect(shell.workspacesByMac[macID]?.workspaces.first?.name == "Fresh Workspace")
    }

    @Test func promotionRejectsSnapshotOlderThanHierarchyMutationRevision() async throws {
        let router = RoutingHostRouter()
        await router.workspaceListGate.setUsesOrdinalTitles(true)
        let macID = "secondary-promotion-mutation"
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [promotionPairedMac(macID: macID)]],
            blockedTeams: []
        )
        await pairedStore.gateLoadAll(number: 2)
        let shell = makeRoutingMultiMacStore(router: router, pairedMacStore: pairedStore)
        try installSecondaryClient(on: shell, macDeviceID: macID, router: router)
        let subscription = try #require(shell.secondaryMacSubscriptions[macID])

        let switchTask = Task { @MainActor in
            await shell.switchToMac(macDeviceID: macID)
        }
        // The promotion snapshot has returned, but it has not crossed its final
        // authority boundary yet.
        await pairedStore.waitUntilLoadAllStarted(number: 2)

        subscription.hierarchyMutationRevision &+= 1
        shell.mergeScopedSecondaryWorkspaceState(
            macID: macID,
            workspaces: [MobileWorkspacePreview(
                id: .init(rawValue: RoutingHostRouter.workspaceID),
                macDeviceID: macID,
                name: "Mutated Workspace",
                terminals: []
            )],
            actionCapabilities: .none
        )
        #expect(shell.workspacesByMac[macID]?.workspaces.first?.name == "Mutated Workspace")

        await pairedStore.releaseLoadAll(number: 2)
        let switched = await switchTask.value

        #expect(!switched)
        #expect(shell.foregroundMacDeviceID != macID)
        #expect(shell.workspacesByMac[macID]?.workspaces.first?.name == "Mutated Workspace")
    }

    private func promotionPairedMac(macID: String) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: macID,
            displayName: "Secondary Mac",
            routes: [],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-a"
        )
    }
}
