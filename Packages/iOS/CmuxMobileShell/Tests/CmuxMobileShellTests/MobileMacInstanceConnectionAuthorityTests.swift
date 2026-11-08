import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileMacInstanceConnectionAuthorityTests {
    @Test func storedTagARejectsStatusTagBAndPreservesRecord() async throws {
        let fixture = try await makeFixture(storedTag: "feature-a", reportedTag: "feature-b")
        defer { fixture.cleanup() }

        #expect(!fixture.didConnect)
        let mac = try #require(await fixture.store.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        ))
        #expect(mac.instanceTag == "feature-a")
        #expect(mac.routes == [fixture.storedRoute])
    }

    @Test func storedTagAPreservesAuthorityForAuthenticatedLegacyStatus() async throws {
        let fixture = try await makeFixture(storedTag: "feature-a", reportedTag: nil)
        defer { fixture.cleanup() }

        #expect(fixture.didConnect)
        let mac = try #require(await fixture.store.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        ))
        #expect(mac.instanceTag == "feature-a")
    }

    @Test func legacyNilTagAdoptsReportedTagB() async throws {
        let fixture = try await makeFixture(storedTag: nil, reportedTag: "feature-b")
        defer { fixture.cleanup() }

        #expect(fixture.didConnect)
        let mac = try #require(await fixture.store.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        ))
        #expect(mac.instanceTag == "feature-b")
    }

    @Test func freshAttachWithoutReportedTagCannotMutateStoredTaggedAuthority() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let storedRoute = try route(id: "stored-b", port: 55_555)
        try await seed(pairedStore, userID: "user-1", route: storedRoute, tag: "feature-b")
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "test-mac", instanceTag: nil)
        let clock = TestClock()
        let shell = makeShell(
            store: pairedStore,
            router: router,
            userID: "user-1",
            clock: clock
        )

        let connected = await shell.connectPairingURL(
            try attachURL(for: makeTicket(clock: clock))
        )

        #expect(!connected)
        let mac = try #require(await pairedStore.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        ))
        #expect(mac.instanceTag == "feature-b")
        #expect(mac.routes == [storedRoute])
    }

    @Test func freshAuthenticatedLegacyHostIsPersistedWhenUnclaimed() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "test-mac", instanceTag: nil, displayName: "Legacy Studio"
        )
        let clock = TestClock()
        let shell = makeShell(
            store: pairedStore,
            router: router,
            userID: "user-1",
            clock: clock
        )

        let connected = await shell.connectPairingURL(
            try attachURL(for: makeTicket(clock: clock))
        )

        #expect(connected)
        let mac = try #require(await pairedStore.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        ))
        #expect(mac.instanceTag == nil)
        #expect(mac.displayName == "Legacy Studio")
        #expect(!mac.routes.isEmpty)
        #expect(shell.displayPairedMacs.map(\.macDeviceID) == ["test-mac"])
    }

    @Test func explicitRegistryBCommitsOnlyAfterExactStatusAndDropsARouteFallbacks() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let routeA = try route(id: "route-a", port: 55_555)
        let routeB = try route(id: "route-b", port: 56_584)
        try await seed(
            pairedStore,
            userID: "user-1",
            route: routeA,
            tag: "feature-a"
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "test-mac",
            instanceTag: "feature-b",
            displayName: "Studio B"
        )
        let shell = makeShell(store: pairedStore, router: router, userID: "user-1")

        await shell.connectToRegistryInstance(
            device: RegistryDevice(
                deviceId: "test-mac",
                platform: "mac",
                displayName: "Studio",
                lastSeenAt: Date(),
                instances: []
            ),
            instance: RegistryAppInstance(
                tag: "feature-b",
                routes: [routeB],
                lastSeenAt: Date()
            )
        )

        #expect(shell.connectionState == .connected)
        let mac = try #require(await pairedStore.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        ))
        #expect(mac.instanceTag == "feature-b")
        #expect(mac.routes.count == 1)
        #expect(mac.routes.first?.endpoint == routeB.endpoint)
        #expect(!mac.routes.contains(routeA))
    }

    @Test func scanningStableAndNightlyPairingCodesKeepsBothTaggedInstances() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let router = LivenessHostRouter()
        let clock = TestClock()
        let shell = makeShell(
            store: pairedStore,
            router: router,
            userID: "user-1",
            clock: clock
        )

        await router.setHostIdentity(
            deviceID: "test-mac",
            instanceTag: "default",
            displayName: "Studio"
        )
        let stableConnected = await shell.connectPairingURL(
            try attachURL(for: makeTicket(clock: clock))
        )

        await router.setHostIdentity(
            deviceID: "test-mac",
            instanceTag: "nightly",
            displayName: "Studio"
        )
        let nightlyConnected = await shell.connectPairingURL(
            try attachURL(for: makeTicket(clock: clock))
        )

        #expect(stableConnected)
        #expect(nightlyConnected)
        let records = try await pairedStore.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        )
        #expect(records.count == 2)
        #expect(Set(records.compactMap(\.instanceTag)) == Set(["default", "nightly"]))
        #expect(records.first(where: { $0.instanceTag == "default" })?.isActive == false)
        #expect(records.first(where: { $0.instanceTag == "nightly" })?.isActive == true)
    }

    @Test func explicitRegistryBWithoutReportedTagCannotReplaceA() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let routeA = try route(id: "route-a", port: 55_555)
        let routeB = try route(id: "route-b", port: 56_584)
        try await seed(pairedStore, userID: "user-1", route: routeA, tag: "feature-a")
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "test-mac", instanceTag: nil)
        let shell = makeShell(store: pairedStore, router: router, userID: "user-1")

        await shell.connectToRegistryInstance(
            device: RegistryDevice(
                deviceId: "test-mac", platform: "mac", displayName: "Studio",
                lastSeenAt: Date(), instances: []
            ),
            instance: RegistryAppInstance(
                tag: "feature-b", routes: [routeB], lastSeenAt: Date()
            )
        )

        #expect(shell.connectionState == .disconnected)
        let mac = try #require(await pairedStore.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        ))
        #expect(mac.instanceTag == "feature-a")
        #expect(mac.routes == [routeA])
    }

    @Test func compactPairingForUserBDoesNotInheritUserARoutesOrAuthority() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let routeA = try route(id: "user-a-route", port: 55_555)
        try await seed(pairedStore, userID: "user-a", route: routeA, tag: "feature-a")
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "test-mac", instanceTag: "feature-b")
        let clock = TestClock()
        let shell = makeShell(
            store: pairedStore,
            router: router,
            userID: "user-b",
            clock: clock
        )

        let connected = await shell.connectPairingURL(
            try attachURL(for: makeTicket(clock: clock))
        )

        #expect(connected)
        let userB = try #require(await pairedStore.activeMac(
            stackUserID: "user-b", teamID: "team-a"
        ))
        #expect(userB.instanceTag == "feature-b")
        #expect(!userB.routes.contains(routeA))
        let userA = try #require(await pairedStore.activeMac(
            stackUserID: "user-a", teamID: "team-a"
        ))
        #expect(userA.instanceTag == "feature-a")
        #expect(userA.routes == [routeA])
    }

    private struct Fixture {
        let shell: MobileShellComposite
        let store: MobilePairedMacStore
        let directory: URL
        let storedRoute: CmxAttachRoute
        let didConnect: Bool

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture(storedTag: String?, reportedTag: String?) async throws -> Fixture {
        let directory = try makeDirectory()
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let storedRoute = try route(id: "stored", port: 56_584)
        try await seed(pairedStore, userID: "user-1", route: storedRoute, tag: storedTag)
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "test-mac", instanceTag: reportedTag)
        let shell = makeShell(store: pairedStore, router: router, userID: "user-1")
        let didConnect = await shell.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        return Fixture(
            shell: shell,
            store: pairedStore,
            directory: directory,
            storedRoute: storedRoute,
            didConnect: didConnect
        )
    }

    private func makeShell(
        store: MobilePairedMacStore,
        router: LivenessHostRouter,
        userID: String,
        clock: TestClock = TestClock()
    ) -> MobileShellComposite {
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { clock.now }
        )
        return MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: userID),
            teamIDProvider: { "team-a" },
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "instance-authority-\(UUID().uuidString)"
            )!
        )
    }

    private func seed(
        _ store: MobilePairedMacStore,
        userID: String,
        route: CmxAttachRoute,
        tag: String?
    ) async throws {
        try await store.upsert(
            macDeviceID: "test-mac",
            displayName: "Studio",
            routes: [route],
            instanceTag: tag,
            markActive: true,
            stackUserID: userID,
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 10)
        )
    }

    private func route(id: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port)
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
