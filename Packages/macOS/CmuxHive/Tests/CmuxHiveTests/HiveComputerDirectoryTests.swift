import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxHive

/// Scripted registry double: returns a fixed outcome per call.
private struct ScriptedRegistry: DeviceRegistryRefreshing {
    var outcome: DeviceRegistryListOutcome

    func freshRoutes(forMacDeviceID macDeviceID: String, instanceTag: String?) async -> [CmxAttachRoute]? {
        nil
    }

    func listDevices() async -> DeviceRegistryListOutcome {
        outcome
    }
}

private actor ScopeBox {
    var scope: HiveAccountScope

    init(_ scope: HiveAccountScope) {
        self.scope = scope
    }

    func read() -> HiveAccountScope {
        scope
    }

    func set(_ scope: HiveAccountScope) {
        self.scope = scope
    }
}

@MainActor
private func makeTempStore() throws -> (store: MobilePairedMacStore, cleanup: () -> Void) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try MobilePairedMacStore(
        databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
    )
    return (store, { try? FileManager.default.removeItem(at: directory) })
}

private func tailscaleRoute(host: String = "100.64.0.9", port: Int = 8000) throws -> CmxAttachRoute {
    try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: host, port: port)
    )
}

@MainActor
private func makeDirectory(
    registry: DeviceRegistryListOutcome,
    store: MobilePairedMacStore,
    ownDeviceID: String = "self-device",
    stackUserID: String? = "user-1",
    teamID: String? = "team-1"
) -> HiveComputerDirectory {
    HiveComputerDirectory(
        registry: ScriptedRegistry(outcome: registry),
        pairedStore: store,
        presence: nil,
        ownDeviceID: ownDeviceID,
        scopeProvider: { HiveAccountScope(stackUserID: stackUserID, teamID: teamID) },
        linkDecoder: HivePairingLinkDecoder(allowsLoopbackRoutes: false),
        now: { Date(timeIntervalSince1970: 1_000) },
        presenceRetryDelay: { _ in }
    )
}

@Suite struct HiveComputerDirectoryTests {
    @MainActor
    @Test func refreshMergesRegistryAndPairedRows() async throws {
        let (store, cleanup) = try makeTempStore()
        defer { cleanup() }
        let route = try tailscaleRoute()
        // A locally paired Mac the registry no longer lists.
        try await store.upsert(
            macDeviceID: "paired-only",
            displayName: "Old Mini",
            routes: [route],
            instanceTag: "stable",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            now: Date(timeIntervalSince1970: 500)
        )
        let registryDevice = RegistryDevice(
            deviceId: "registry-mac",
            platform: "mac",
            displayName: "Studio",
            lastSeenAt: Date(timeIntervalSince1970: 900),
            instances: [
                RegistryAppInstance(
                    tag: "stable",
                    routes: [route],
                    lastSeenAt: Date(timeIntervalSince1970: 900)
                )
            ]
        )
        let ownDevice = RegistryDevice(
            deviceId: "self-device",
            platform: "mac",
            displayName: "This Mac",
            lastSeenAt: Date(timeIntervalSince1970: 950),
            instances: []
        )
        let directory = makeDirectory(registry: .ok([registryDevice, ownDevice]), store: store)
        await directory.refresh()

        #expect(directory.computers.count == 3)
        #expect(directory.computers.first?.deviceID == "self-device")
        #expect(directory.computers.first?.isThisComputer == true)
        let registryRow = try #require(directory.computers.first { $0.deviceID == "registry-mac" })
        #expect(registryRow.displayName == "Studio")
        #expect(registryRow.isPaired == false)
        #expect(registryRow.isPairableHost)
        let pairedRow = try #require(directory.computers.first { $0.deviceID == "paired-only" })
        #expect(pairedRow.isPaired)
        #expect(pairedRow.displayName == "Old Mini")
        #expect(pairedRow.instances.first?.routes == [route])
    }

    @MainActor
    @Test func scopedUpdatesFollowOnlyTheirDeviceAndSignalRemoval() async throws {
        let (store, cleanup) = try makeTempStore()
        defer { cleanup() }
        let target = RegistryDevice(
            deviceId: "target-mac",
            platform: "mac",
            displayName: "Target",
            lastSeenAt: Date(timeIntervalSince1970: 900),
            instances: []
        )
        let other = RegistryDevice(
            deviceId: "other-mac",
            platform: "mac",
            displayName: "Other",
            lastSeenAt: Date(timeIntervalSince1970: 800),
            instances: []
        )
        let replacement = RegistryDevice(
            deviceId: "other-mac",
            platform: "mac",
            displayName: "Other renamed",
            lastSeenAt: Date(timeIntervalSince1970: 1_000),
            instances: []
        )
        let directory = HiveComputerDirectory(
            registry: SequencedRegistry([
                .ok([target, other]),
                .ok([replacement]),
            ]),
            pairedStore: store,
            presence: nil,
            ownDeviceID: "self-device",
            scopeProvider: { HiveAccountScope(stackUserID: "user-1", teamID: "team-1") },
            linkDecoder: HivePairingLinkDecoder(allowsLoopbackRoutes: false),
            now: { Date(timeIntervalSince1970: 1_000) },
            presenceRetryDelay: { _ in }
        )

        await directory.refresh()
        var targetIterator = directory.updates(for: "TARGET-MAC").makeAsyncIterator()
        var otherIterator = directory.updates(for: "other-mac").makeAsyncIterator()
        let initialTargetEvent = try #require(await targetIterator.next())
        let initialTarget = try #require(initialTargetEvent)
        let initialOtherEvent = try #require(await otherIterator.next())
        let initialOther = try #require(initialOtherEvent)
        #expect(initialTarget.deviceID == "target-mac")
        #expect(initialOther.deviceID == "other-mac")

        await directory.refresh()
        let removedTarget = try #require(await targetIterator.next())
        #expect(removedTarget == nil)
        let updatedOtherEvent = try #require(await otherIterator.next())
        let updatedOther = try #require(updatedOtherEvent)
        #expect(updatedOther.displayName == "Other renamed")
    }

    @MainActor
    @Test func pairFromRegistryPersistsBestRoutes() async throws {
        let (store, cleanup) = try makeTempStore()
        defer { cleanup() }
        let route = try tailscaleRoute()
        let device = RegistryDevice(
            deviceId: "registry-mac",
            platform: "mac",
            displayName: "Studio",
            lastSeenAt: Date(timeIntervalSince1970: 900),
            instances: [
                RegistryAppInstance(tag: "empty", routes: [], lastSeenAt: Date(timeIntervalSince1970: 999)),
                RegistryAppInstance(tag: "stable", routes: [route], lastSeenAt: Date(timeIntervalSince1970: 900)),
            ]
        )
        let directory = makeDirectory(registry: .ok([device]), store: store)
        await directory.refresh()

        let outcome = await directory.pair(deviceID: "registry-mac")
        #expect(outcome == .paired(deviceID: "registry-mac"))

        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.count == 1)
        #expect(persisted.first?.macDeviceID == "registry-mac")
        #expect(persisted.first?.routes == [route])
        #expect(persisted.first?.instanceTag == "stable")
        #expect(directory.computers.first { $0.deviceID == "registry-mac" }?.isPaired == true)
    }

    @MainActor
    @Test func pairRejectsSelfAndRouteless() async throws {
        let (store, cleanup) = try makeTempStore()
        defer { cleanup() }
        let ownDevice = RegistryDevice(
            deviceId: "self-device",
            platform: "mac",
            displayName: "This Mac",
            lastSeenAt: Date(timeIntervalSince1970: 950),
            instances: [
                RegistryAppInstance(
                    tag: "stable",
                    routes: [try tailscaleRoute()],
                    lastSeenAt: Date(timeIntervalSince1970: 900)
                )
            ]
        )
        let routeless = RegistryDevice(
            deviceId: "routeless-mac",
            platform: "mac",
            displayName: "Sleepy",
            lastSeenAt: Date(timeIntervalSince1970: 800),
            instances: [
                RegistryAppInstance(tag: "stable", routes: [], lastSeenAt: Date(timeIntervalSince1970: 800))
            ]
        )
        let phone = RegistryDevice(
            deviceId: "phone",
            platform: "ios",
            displayName: "iPhone",
            lastSeenAt: Date(timeIntervalSince1970: 700),
            instances: []
        )
        let directory = makeDirectory(registry: .ok([ownDevice, routeless, phone]), store: store)
        await directory.refresh()

        // Self-pairing is refused outright, even though dev builds advertise
        // routes for this device.
        #expect(await directory.pair(deviceID: "self-device") == .loopbackRejected)
        #expect(await directory.pair(deviceID: "routeless-mac") == .noRoutes)
        #expect(await directory.pair(deviceID: "phone") == .noRoutes)
        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.isEmpty)
    }

    @MainActor
    @Test func unpairRemovesOnlyTheLocalRecord() async throws {
        let (store, cleanup) = try makeTempStore()
        defer { cleanup() }
        let route = try tailscaleRoute()
        let device = RegistryDevice(
            deviceId: "registry-mac",
            platform: "mac",
            displayName: "Studio",
            lastSeenAt: Date(timeIntervalSince1970: 900),
            instances: [
                RegistryAppInstance(tag: "stable", routes: [route], lastSeenAt: Date(timeIntervalSince1970: 900))
            ]
        )
        let directory = makeDirectory(registry: .ok([device]), store: store)
        await directory.refresh()
        _ = await directory.pair(deviceID: "registry-mac")

        #expect(await directory.unpair(deviceID: "registry-mac"))
        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.isEmpty)
        // The registry row stays visible, just unpaired.
        let row = try #require(directory.computers.first { $0.deviceID == "registry-mac" })
        #expect(row.isPaired == false)
    }

    @MainActor
    @Test func unpairAfterSignOutDoesNotDeleteScopedRecords() async throws {
        let (store, cleanup) = try makeTempStore()
        defer { cleanup() }
        let route = try tailscaleRoute()
        let device = RegistryDevice(
            deviceId: "registry-mac",
            platform: "mac",
            displayName: "Studio",
            lastSeenAt: Date(timeIntervalSince1970: 900),
            instances: [RegistryAppInstance(tag: "stable", routes: [route], lastSeenAt: Date(timeIntervalSince1970: 900))]
        )
        let scopeBox = ScopeBox(HiveAccountScope(stackUserID: "user-1", teamID: "team-1"))
        let directory = HiveComputerDirectory(
            registry: ScriptedRegistry(outcome: .ok([device])),
            pairedStore: store,
            presence: nil,
            ownDeviceID: "self-device",
            scopeProvider: { await scopeBox.read() },
            linkDecoder: HivePairingLinkDecoder(allowsLoopbackRoutes: false),
            now: { Date(timeIntervalSince1970: 1_000) },
            presenceRetryDelay: { _ in }
        )
        await directory.refresh()
        var scopedIterator = directory.updates(for: "registry-mac").makeAsyncIterator()
        let initialScopedEvent = try #require(await scopedIterator.next())
        _ = try #require(initialScopedEvent)
        #expect(await directory.pair(deviceID: "registry-mac") == .paired(deviceID: "registry-mac"))

        await scopeBox.set(HiveAccountScope(stackUserID: nil, teamID: nil))
        directory.clearForSignOut()
        let removedScopedEvent = try #require(await scopedIterator.next())
        #expect(removedScopedEvent == nil)
        #expect(await directory.unpair(deviceID: "registry-mac") == false)
        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.count == 1)
    }

    @MainActor
    @Test func transientRegistryFailureKeepsPreviousRows() async throws {
        let (store, cleanup) = try makeTempStore()
        defer { cleanup() }
        let device = RegistryDevice(
            deviceId: "registry-mac",
            platform: "mac",
            displayName: "Studio",
            lastSeenAt: Date(timeIntervalSince1970: 900),
            instances: []
        )
        let directory = makeDirectory(registry: .ok([device]), store: store)
        await directory.refresh()
        #expect(directory.computers.count == 1)

        let scripted = SequencedRegistry([.ok([device]), .transientFailure])
        let warm = HiveComputerDirectory(
            registry: scripted,
            pairedStore: store,
            presence: nil,
            ownDeviceID: "self-device",
            scopeProvider: { HiveAccountScope(stackUserID: "user-1", teamID: "team-1") },
            linkDecoder: HivePairingLinkDecoder(allowsLoopbackRoutes: false),
            now: { Date(timeIntervalSince1970: 1_000) },
            presenceRetryDelay: { _ in }
        )
        await warm.refresh()
        await warm.refresh()
        #expect(warm.lastRefreshFailed)
        #expect(warm.computers.count == 1)
    }

    @MainActor
    @Test func presenceSnapshotMarksDevicesOnline() throws {
        let route = try tailscaleRoute()
        var map = PresenceMap()
        // Feed the map a wire-shaped snapshot frame, the same JSON the
        // presence worker pushes on subscribe.
        let snapshotJSON = """
        {
          "type": "snapshot",
          "teamId": "team-1",
          "now": 1000000,
          "heartbeatIntervalMs": 15000,
          "offlineTimeoutMs": 45000,
          "devices": [
            {
              "deviceId": "registry-mac",
              "platform": "mac",
              "displayName": "Studio",
              "online": true,
              "lastSeenAt": 1000000,
              "instances": [
                {
                  "deviceId": "registry-mac",
                  "tag": "stable",
                  "platform": "mac",
                  "capabilities": [],
                  "online": true,
                  "lastSeenAt": 1000000
                }
              ]
            }
          ]
        }
        """
        map.apply(try PresenceUpdate.parse(Data(snapshotJSON.utf8)))
        let registryDevice = RegistryDevice(
            deviceId: "registry-mac",
            platform: "mac",
            displayName: "Studio",
            lastSeenAt: Date(timeIntervalSince1970: 900),
            instances: [
                RegistryAppInstance(tag: "stable", routes: [route], lastSeenAt: Date(timeIntervalSince1970: 900))
            ]
        )
        let offlineDevice = RegistryDevice(
            deviceId: "other-mac",
            platform: "mac",
            displayName: "Mini",
            lastSeenAt: Date(timeIntervalSince1970: 800),
            instances: []
        )
        let rows = HiveComputerRowBuilder(ownDeviceID: "self-device").makeRows(
            registry: [registryDevice, offlineDevice],
            paired: [],
            presence: map
        )
        let online = try #require(rows.first { $0.deviceID == "registry-mac" })
        #expect(online.presence == .online)
        #expect(online.instances.first?.isOnline == true)
        let unknown = try #require(rows.first { $0.deviceID == "other-mac" })
        #expect(unknown.presence == .unknown(lastSeenAt: Date(timeIntervalSince1970: 800)))
        // Online rows sort before unknown/offline rows.
        #expect(rows.first?.deviceID == "registry-mac")
    }

    @MainActor
    @Test func pairFromV2TailscaleLinkRequiresRegistryIdentity() async throws {
        let (store, cleanup) = try makeTempStore()
        defer { cleanup() }
        // A v2 pairing link (the QR payload) names routes only, never a
        // device id; encode one exactly like another Mac's pairing window.
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-b",
            macDisplayName: "Studio",
            macUserID: "user-1",
            macPairingCompatibilityVersion: 0,
            routes: [
                try CmxAttachRoute(
                    id: "tailscale",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "100.64.0.7", port: 8123),
                    priority: 10
                )
            ],
            expiresAt: nil
        )
        let link = try #require(CmxPairingQRCode().encode(ticket, routeDisclosureMode: .legacyPrivateNetworkCompatibility))
        let directory = makeDirectory(registry: .ok([]), store: store)

        let outcome = await directory.pair(link: link)
        #expect(outcome == .unsupportedManualRoute)
        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.isEmpty)
        #expect(directory.computers.isEmpty)
    }

    @MainActor
    @Test func bestPairingRoutesPrefersOnlineThenFreshest() throws {
        let routeA = try tailscaleRoute(host: "100.64.0.1")
        let routeB = try tailscaleRoute(host: "100.64.0.2")
        let computer = HiveComputer(
            deviceID: "mac",
            displayName: "Mac",
            platform: "mac",
            isThisComputer: false,
            isPaired: false,
            presence: .online,
            instances: [
                HiveComputerInstance(
                    tag: "fresh-offline",
                    routes: [routeA],
                    lastSeenAt: Date(timeIntervalSince1970: 900),
                    isOnline: false
                ),
                HiveComputerInstance(
                    tag: "older-online",
                    routes: [routeB],
                    lastSeenAt: Date(timeIntervalSince1970: 100),
                    isOnline: true
                ),
            ]
        )
        let best = try #require(computer.bestPairingRoutes)
        #expect(best.instanceTag == "older-online")
        #expect(best.routes == [routeB])
    }
}

/// pair(code:) — the registry-rendezvous claim for the 6-digit code another
/// Mac's "Pair This Mac" row shows. The directory's injected clock is epoch
/// 1000, so labels expiring at epoch 2000 are live and epoch 500 expired.
@Suite struct HiveComputerDirectoryPairByCodeTests {
    private static let liveExpiry = "1970-01-01T00:33:20Z" // epoch 2000
    private static let pastExpiry = "1970-01-01T00:08:20Z" // epoch 500

    private func codedDevice(
        deviceId: String,
        code: String,
        expiry: String = Self.liveExpiry,
        tag: String = "stable",
        route: CmxAttachRoute
    ) -> RegistryDevice {
        RegistryDevice(
            deviceId: deviceId,
            platform: "mac",
            displayName: "Coded Mac",
            lastSeenAt: Date(timeIntervalSince1970: 950),
            instances: [
                RegistryAppInstance(
                    tag: tag,
                    routes: [route],
                    lastSeenAt: Date(timeIntervalSince1970: 900),
                    labels: [
                        CmxPairingCode.codeLabelKey: code,
                        CmxPairingCode.expiresAtLabelKey: expiry,
                    ]
                )
            ]
        )
    }

    @MainActor
    @Test func pairByCodeClaimsTheUniqueLiveMatch() async throws {
        let (store, cleanup) = try makeTempStore()
        defer { cleanup() }
        let route = try tailscaleRoute()
        let device = codedDevice(deviceId: "coded-mac", code: "042117", route: route)
        let directory = makeDirectory(registry: .ok([device]), store: store)

        let outcome = await directory.pair(code: " 042 117 ")
        #expect(outcome == .paired(deviceID: "coded-mac"))

        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.count == 1)
        #expect(persisted.first?.macDeviceID == "coded-mac")
        #expect(persisted.first?.routes == [route])
        #expect(persisted.first?.instanceTag == "stable")
    }

    @MainActor
    @Test func pairByCodeRejectsWrongExpiredAndMalformedCodes() async throws {
        let (store, cleanup) = try makeTempStore()
        defer { cleanup() }
        let live = codedDevice(deviceId: "coded-mac", code: "042117", route: try tailscaleRoute())
        let expired = codedDevice(
            deviceId: "expired-mac",
            code: "555555",
            expiry: Self.pastExpiry,
            route: try tailscaleRoute(host: "100.64.0.10")
        )
        let directory = makeDirectory(registry: .ok([live, expired]), store: store)

        #expect(await directory.pair(code: "000000") == .codeNotFound)
        #expect(await directory.pair(code: "555555") == .codeNotFound)
        #expect(await directory.pair(code: "4211") == .codeNotFound)
        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.isEmpty)
    }

    @MainActor
    @Test func pairByCodeRefusesAmbiguousDuplicates() async throws {
        let (store, cleanup) = try makeTempStore()
        defer { cleanup() }
        let first = codedDevice(deviceId: "mac-a", code: "042117", route: try tailscaleRoute())
        let second = codedDevice(
            deviceId: "mac-b",
            code: "042117",
            route: try tailscaleRoute(host: "100.64.0.11")
        )
        let directory = makeDirectory(registry: .ok([first, second]), store: store)

        #expect(await directory.pair(code: "042117") == .codeNotFound)
        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.isEmpty)
    }

    @MainActor
    @Test func pairByCodeRejectsThisMacsOwnCode() async throws {
        let (store, cleanup) = try makeTempStore()
        defer { cleanup() }
        let own = codedDevice(deviceId: "self-device", code: "042117", route: try tailscaleRoute())
        let directory = makeDirectory(registry: .ok([own]), store: store)

        #expect(await directory.pair(code: "042117") == .loopbackRejected)
        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.isEmpty)
    }
}
