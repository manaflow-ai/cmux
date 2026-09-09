import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxHive

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HiveIdentityAndRoutePolicyTests {
    private let fixture = HiveDirectoryTestFixture()
    private let upperID = "ABCD1234-AAAA-BBBB-CCCC-1234567890AB"

    @Test func uuidCasingMergesPairingsAndSurvivesIncrementalPresence() async throws {
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        let route = try fixture.tailscaleRoute()
        try await store.upsert(
            macDeviceID: upperID.lowercased(), displayName: "Paired",
            routes: [route], instanceTag: "stable", markActive: false,
            stackUserID: "user-1", teamID: "team-1", now: Date(timeIntervalSince1970: 950)
        )
        let feed = HivePresenceTestFeed()
        let directory = makeDirectory(
            devices: [device(id: upperID, routes: [route])], store: store, presence: feed
        )
        defer { directory.clearForSignOut(); feed.events.continuation.finish() }
        await directory.refresh()
        #expect(directory.computers.count == 1)
        #expect(directory.computers.first?.deviceID == upperID.lowercased())
        #expect(directory.computers.first?.isPaired == true)
        var rows = directory.updates(for: upperID).makeAsyncIterator()
        _ = await rows.next()

        let liveRoute = try fixture.tailscaleRoute(host: "100.64.0.20")
        feed.events.continuation.yield(.routes(PresenceInstance(
            deviceId: upperID.lowercased(), tag: "stable", platform: "mac",
            online: true, lastSeenAt: 1_100_000, routes: [liveRoute]
        )))
        let updated = try #require(await rows.next())
        #expect(updated?.deviceID == upperID.lowercased())
        #expect(updated?.isPaired == true)
        #expect(updated?.platform == "mac")
        #expect(updated?.instances.first?.routes.first == liveRoute)
        #expect(directory.computers.count == 1)
        #expect(await directory.pair(deviceID: upperID) == .paired(deviceID: upperID.lowercased()))
        #expect(await directory.unpair(deviceID: upperID))
        #expect(directory.computers.count == 1)
        #expect(directory.computers.first?.isPaired == false)
    }

    @Test func opaqueDeviceIDsKeepTheirCaseAndDoNotShareScopedUpdates() async throws {
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        let route = try fixture.tailscaleRoute()
        let registry = HiveDirectoryTestFixture.Registry(outcome: .ok([
            device(id: "Opaque-Host", routes: [route]), device(id: "opaque-host", routes: [route])
        ]))
        let feed = HivePresenceTestFeed()
        defer { feed.events.continuation.finish() }
        let directory = HiveComputerDirectory(
            registry: registry, pairedStore: store, presence: feed, ownDeviceID: "Opaque-Host",
            scopeProvider: { HiveAccountScope(stackUserID: "user-1", teamID: "team-1") },
            linkDecoder: HivePairingLinkDecoder(allowsLoopbackRoutes: false), presenceRetryDelay: { _ in }
        )
        await directory.refresh()
        #expect(directory.computers.count == 2)
        #expect(directory.computers.filter(\.isThisComputer).map(\.deviceID) == ["Opaque-Host"])
        var lowerRows = directory.updates(for: "opaque-host").makeAsyncIterator()
        let row = try #require(await lowerRows.next())
        #expect(row?.deviceID == "opaque-host")
        feed.events.continuation.yield(.routes(PresenceInstance(
            deviceId: "opaque-host", tag: "stable", platform: "mac",
            online: true, lastSeenAt: 1_100_000, routes: [route]
        )))
        let updated = try #require(await lowerRows.next())
        #expect(updated?.deviceID == "opaque-host")
        #expect(updated?.isThisComputer == false)
        directory.clearForSignOut()
    }

    @Test(arguments: [false, true])
    func rowAndCodePairingRespectLoopbackPolicy(allowsLoopback: Bool) async throws {
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        let loopback = try CmxAttachRoute(
            id: "loopback", kind: .debugLoopback, endpoint: .hostPort(host: "127.0.0.1", port: 8000)
        )
        let directory = makeDirectory(
            devices: [device(id: "loopback-host", routes: [loopback])],
            store: store, allowsLoopback: allowsLoopback
        )
        await directory.refresh()
        #expect(directory.computers.first?.hasViewerSupportedRoute == allowsLoopback)
        let expected: HivePairOutcome = allowsLoopback ? .paired(deviceID: "loopback-host") : .noRoutes
        #expect(await directory.pair(deviceID: "loopback-host") == expected)
        #expect(await directory.pair(code: "042117") == expected)
        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.isEmpty == !allowsLoopback)
    }

    @Test func releaseSelectsAnOlderSupportedInstanceBeforeAFreshLoopbackInstance() async throws {
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        let tailscale = try fixture.tailscaleRoute()
        let loopback = try CmxAttachRoute(
            id: "loopback", kind: .debugLoopback, endpoint: .hostPort(host: "127.0.0.1", port: 8000)
        )
        var host = device(id: "mixed-host", routes: [tailscale])
        host.instances.append(RegistryAppInstance(
            tag: "dev", routes: [loopback], lastSeenAt: Date(timeIntervalSince1970: 999)
        ))
        let directory = makeDirectory(devices: [host], store: store)
        await directory.refresh()
        #expect(directory.computers.first?.bestPairingRoutes?.routes == [tailscale])
        #expect(directory.computers.first?.bestPairingRoutes?.instanceTag == "stable")
        #expect(await directory.pair(deviceID: "mixed-host") == .paired(deviceID: "mixed-host"))
        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.first?.routes == [tailscale])
    }

    private func device(id: String, routes: [CmxAttachRoute]) -> RegistryDevice {
        RegistryDevice(
            deviceId: id, platform: "mac", displayName: id,
            lastSeenAt: Date(timeIntervalSince1970: 900),
            instances: [RegistryAppInstance(
                tag: "stable", routes: routes, lastSeenAt: Date(timeIntervalSince1970: 900),
                labels: [CmxPairingCode.codeLabelKey: "042117", CmxPairingCode.expiresAtLabelKey: "1970-01-01T00:33:20Z"]
            )]
        )
    }

    private func makeDirectory(
        devices: [RegistryDevice], store: MobilePairedMacStore,
        presence: (any PresenceSubscribing)? = nil, allowsLoopback: Bool = false
    ) -> HiveComputerDirectory {
        HiveComputerDirectory(
            registry: HiveDirectoryTestFixture.Registry(outcome: .ok(devices)),
            pairedStore: store, presence: presence, ownDeviceID: "self-device",
            scopeProvider: { HiveAccountScope(stackUserID: "user-1", teamID: "team-1") },
            linkDecoder: HivePairingLinkDecoder(allowsLoopbackRoutes: allowsLoopback),
            now: { Date(timeIntervalSince1970: 1_000) }, presenceRetryDelay: { _ in }
        )
    }
}
