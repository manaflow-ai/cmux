import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

// Keep this in the serialized backup suite: its HTTP fixture is shared with
// the other migration tests. Only the network and remote Mac are simulated;
// restore, SQLite migration, discovery admission and persistence are real.
extension PairedMacBackupMigrationTests {
    @MainActor
    @Test(arguments: [false, true])
    func firstAppStoreLaunchAfterBetaAndInternalMigratesTailscaleThenDiscoversIroh(
        hasPreviouslyImportedLocalRecords: Bool
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-store-first-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsSuite = "app-store-first-launch-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite) }
        let appNamespace = try #require(MobileIOSAppNamespace(bundleIdentifier: "com.cmux.app"))
        #expect(appNamespace.legacyBackupScope == .unscoped)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let discoveryDate = Date()

        // The old BETA/INTERNAL sessions have separate local databases but
        // historically contributed to the same unscoped server backup.
        var oldSessions: [(store: MobilePairedMacStore, rows: [MobilePairedMac])] = []
        var legacyRecords: [PairedMacBackupRecord] = []
        for (session, endpointByte) in [("beta", "a"), ("internal", "b")] {
            let store = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent(
                "dev.cmux.app.\(session).sqlite3"
            ))
            let tailscale = try CmxAttachRoute(
                id: "\(session)-tailscale", kind: .tailscale,
                endpoint: .hostPort(host: session == "beta" ? "100.64.0.20" : "100.64.0.21", port: 8443)
            )
            let oldIroh = try firstLaunchIrohRoute(id: "\(session)-retired-iroh", byte: endpointByte)
            for (suffix, routes) in [
                ("mixed", [tailscale, oldIroh]),
                ("tailscale-only", [tailscale]),
                ("iroh-only", [oldIroh]),
            ] {
                let id = "\(session)-\(suffix)"
                try await store.upsert(
                    macDeviceID: id, displayName: id, routes: routes, instanceTag: "nightly",
                    markActive: session == "beta" && suffix == "mixed", stackUserID: "user-1", now: oldDate
                )
                try await store.setCustomization(
                    macDeviceID: id, instanceTag: "nightly", customName: "Saved \(id)",
                    customColor: "palette:2", customIcon: "desktopcomputer",
                    stackUserID: "user-1", now: oldDate
                )
            }
            let rows = try await store.loadAll(stackUserID: "user-1")
            #expect(rows.count == 3)
            oldSessions.append((store, rows))
            legacyRecords += rows.map { mac in
                PairedMacBackupRecord(
                    macDeviceID: mac.macDeviceID, displayName: mac.displayName, routes: mac.routes,
                    createdAt: mac.createdAt.timeIntervalSince1970 * 1_000,
                    lastSeenAt: mac.lastSeenAt.timeIntervalSince1970 * 1_000,
                    isActive: mac.isActive, customName: mac.customName,
                    customColor: mac.customColor, customIcon: mac.customIcon, instanceTag: mac.instanceTag
                )
            }
        }
        let tailscaleRecords = legacyRecords.compactMap { record -> PairedMacBackupRecord? in
            var record = record
            record.routes.removeAll { $0.kind != .tailscale }
            return record.routes.isEmpty ? nil : record
        }
        #expect(tailscaleRecords.count == 4)
        let databaseURL = directory.appendingPathComponent("com.cmux.app.sqlite3")
        if hasPreviouslyImportedLocalRecords {
            let previousImport = try MobilePairedMacStore(databaseURL: databaseURL)
            for record in legacyRecords {
                try await previousImport.upsert(
                    macDeviceID: record.macDeviceID, displayName: record.displayName,
                    routes: record.routes, instanceTag: record.instanceTag,
                    markActive: false, stackUserID: "user-1", now: oldDate.addingTimeInterval(-1)
                )
                try await previousImport.setCustomization(
                    macDeviceID: record.macDeviceID, instanceTag: record.instanceTag,
                    customName: record.customName, customColor: record.customColor,
                    customIcon: record.customIcon, stackUserID: "user-1", now: oldDate
                )
            }
        }
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: appNamespace.serverScope,
            primaryResponse: try JSONEncoder().encode(TestBackupList(
                records: [], deletedMacDeviceIDs: [], revision: 0, teamId: "team-1"
            )),
            legacyScope: nil,
            legacyResponse: try JSONEncoder().encode(TestBackupList(
                records: legacyRecords, deletedMacDeviceIDs: [], teamId: "team-1"
            )),
            primaryResponseAfterUpload: try JSONEncoder().encode(TestBackupList(
                records: tailscaleRecords, deletedMacDeviceIDs: [], revision: 1, teamId: "team-1"
            ))
        )
        let backup = try firstLaunchBackupClient(namespace: appNamespace, defaultsSuite: defaultsSuite)
        let local = try MobilePairedMacStore(databaseURL: databaseURL, migrateAppStoreRoutes: true)
        let store = BackingUpPairedMacStore(inner: local, backup: backup)
        let discovery = FirstLaunchIrohDiscovery()
        let router = LivenessHostRouter()
        let freshRoute = try firstLaunchIrohRoute(id: "app-store-fresh-iroh", byte: "f")
        await router.setHostIdentity(
            deviceID: "internal-iroh-only", instanceTag: "nightly", displayName: "Fresh Mac",
            clientNamespace: "mac:com.cmuxterm.app.nightly",
            appVersion: "0.64.22-nightly.3359013153901"
        )
        let factory = FirstLaunchRouteFactory(route: freshRoute, router: router)
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory, now: { discoveryDate }, supportedRouteKinds: [.tailscale, .iroh]
            ),
            isSignedIn: true, pairedMacStore: store, buildCompatibilityPolicy: .official,
            personalIrohDiscovery: discovery,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: try #require(UserDefaults(suiteName: defaultsSuite)),
            multiMacAggregationDefaults: try #require(UserDefaults(suiteName: defaultsSuite))
        )
        defer { shell.disconnectLiveConnection() }

        // First list load restores from the legacy backup into the NEW app's
        // container. No Iroh result has been supplied by discovery yet.
        await shell.loadPairedMacs()
        let restored = try await local.loadAll(stackUserID: "user-1")
        #expect(Set(restored.map(\.macDeviceID)) == Set(tailscaleRecords.map(\.macDeviceID)))
        #expect(Set(shell.pairedMacs.map(\.macDeviceID)) == Set(restored.map(\.macDeviceID)))
        for record in tailscaleRecords {
            let saved = try #require(restored.first { $0.macDeviceID == record.macDeviceID })
            #expect(saved.routes == record.routes)
            #expect(saved.customName == record.customName)
            #expect(saved.customColor == record.customColor)
            #expect(saved.customIcon == record.customIcon)
        }
        #expect(!(await shell.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(discovery.calls > 0)
        #expect(factory.attemptedRoutes().isEmpty)

        // Check the migration write itself, not just the fixture's response:
        // the old endpoints must never be copied to the App Store collection.
        let migrationBodies = PairedMacBackupMigrationURLProtocol.capturedRequestBodies().compactMap { $0 }
        #expect(migrationBodies.count == 1)
        let body = try #require(migrationBodies.first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let ops = try #require(json["ops"] as? [[String: Any]])
        #expect(ops.count == 4)
        for op in ops {
            let record = try #require(op["record"] as? [String: Any])
            let routes = try #require(record["routes"] as? [[String: Any]])
            #expect(routes.compactMap { $0["kind"] as? String } == ["tailscale"])
        }

        // Rediscover the SAME previously Iroh-only Mac under a new endpoint.
        // Production reconnect must authenticate it before creating the row;
        // the test never inserts the fresh route directly into the store.
        discovery.candidates = [MobileDiscoveredIrohMac(
            deviceID: "internal-iroh-only", displayName: "Fresh Mac", instanceTag: "nightly",
            routes: [freshRoute], lastSeenAt: discoveryDate
        )]
        // Use the user Retry entrypoint to clear the deliberate backoff from
        // the empty first discovery response.
        await router.delayHostStatusRequest(number: 1)
        let reconnect = Task { @MainActor in
            await shell.retryActiveMacReconnect(stackUserID: "user-1")
        }
        #expect(await router.waitForCount(of: "mobile.host.status", atLeast: 1))
        let beforeAdmission = try? await local.loadAll(stackUserID: "user-1")
        #expect(beforeAdmission?.count == 4)
        #expect(beforeAdmission?.contains { $0.macDeviceID == "internal-iroh-only" } == false)
        await router.releaseAllHeld()
        #expect(await reconnect.value)
        #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        #expect(shell.connectionState == .connected)
        #expect(factory.attemptedRoutes() == [freshRoute])
        let afterDiscovery = try await local.loadAll(stackUserID: "user-1")
        #expect(afterDiscovery.count == 5)
        let discovered = try #require(afterDiscovery.first { $0.macDeviceID == "internal-iroh-only" })
        #expect(discovered.routes == [freshRoute])
        #expect(discovered.instanceTag == "nightly")
        #expect(discovered.isActive)
        #expect(!afterDiscovery.contains { $0.macDeviceID == "beta-iroh-only" })
        for record in tailscaleRecords {
            #expect(afterDiscovery.first { $0.macDeviceID == record.macDeviceID }?.routes == record.routes)
        }
        await shell.loadPairedMacs()
        #expect(Set(shell.pairedMacs.map(\.macDeviceID)) == Set(afterDiscovery.map(\.macDeviceID)))
        await shell.remoteClient?.disconnect()
        shell.disconnectLiveConnection()

        // Reopening with the first-launch migration enabled must not delete
        // the authenticated Iroh route or restore any retired backup route.
        let reopened = try MobilePairedMacStore(databaseURL: databaseURL, migrateAppStoreRoutes: true)
        let relaunched = BackingUpPairedMacStore(inner: reopened, backup: backup)
        let afterRelaunch = try await relaunched.loadAll(stackUserID: "user-1")
        #expect(afterRelaunch.count == 5)
        #expect(afterRelaunch.first { $0.macDeviceID == discovered.macDeviceID }?.routes == [freshRoute])
        let retiredRoutes = legacyRecords.flatMap(\.routes).filter { $0.kind == .iroh }
        #expect(afterRelaunch.flatMap(\.routes).allSatisfy { !retiredRoutes.contains($0) })
        for session in oldSessions {
            #expect(try await session.store.loadAll(stackUserID: "user-1") == session.rows)
        }
        #expect(PairedMacBackupMigrationURLProtocol.capturedRequests().filter {
            $0.httpMethod == "POST"
        }.allSatisfy { $0.value(forHTTPHeaderField: "X-Cmux-Client-Scope") == appNamespace.serverScope })
    }
}

private func firstLaunchBackupClient(
    namespace: MobileIOSAppNamespace,
    defaultsSuite: String
) throws -> PairedMacBackupClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PairedMacBackupMigrationURLProtocol.self]
    let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
    return PairedMacBackupClient(
        serviceBaseURL: "https://presence.example",
        tokenSource: PresenceTokenSource(accessToken: { "token" }, currentUserID: { "user-1" }),
        clientScopeProvider: { namespace.serverScope }, legacyClientScopeProvider: { nil },
        restoreRouteFilter: { $0.kind == .tailscale },
        session: URLSession(configuration: configuration),
        migrationDefaults: defaults
    )
}

private func firstLaunchIrohRoute(id: String, byte: String) throws -> CmxAttachRoute {
    try CmxAttachRoute(
        id: id, kind: .iroh,
        endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: String(repeating: byte, count: 64)), pathHints: [])
    )
}

@MainActor
private final class FirstLaunchIrohDiscovery: MobileIrohMacDiscovering {
    var candidates: [MobileDiscoveredIrohMac] = []
    private(set) var calls = 0

    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        calls += 1
        return candidates
    }

    func invalidateDiscovery(forMacDeviceID _: String) async {}
}

private final class FirstLaunchRouteFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let route: CmxAttachRoute
    private let router: LivenessHostRouter
    private let lock = NSLock()
    private var attempts: [CmxAttachRoute] = []

    init(route: CmxAttachRoute, router: LivenessHostRouter) {
        self.route = route
        self.router = router
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        lock.withLock { attempts.append(route) }
        guard route == self.route else {
            throw URLError(.cannotConnectToHost)
        }
        return LivenessTransport(router: router)
    }

    func attemptedRoutes() -> [CmxAttachRoute] {
        lock.withLock { attempts }
    }
}
