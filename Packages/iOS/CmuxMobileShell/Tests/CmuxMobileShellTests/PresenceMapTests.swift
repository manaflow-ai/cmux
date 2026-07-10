import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

/// Behavior of the phone-side presence reduction: snapshot replace, transition
/// upserts, `seen` ticks, and the per-device rollup the device tree rows read.
@Suite struct PresenceMapTests {
    private func instance(
        deviceId: String,
        tag: String = "default",
        transportMode: String? = nil,
        online: Bool = true,
        lastSeenAt: Double = 1_000
    ) -> PresenceInstance {
        PresenceInstance(
            deviceId: deviceId,
            tag: tag,
            platform: "mac",
            transportMode: transportMode,
            online: online,
            lastSeenAt: lastSeenAt
        )
    }

    private func snapshot(_ instances: [PresenceInstance]) -> PresenceUpdate {
        let byDevice = Dictionary(grouping: instances, by: \.deviceId)
        let devices = byDevice.map { deviceId, instances in
            PresenceDevice(
                deviceId: deviceId,
                platform: "mac",
                displayName: nil,
                online: instances.contains(where: \.online),
                lastSeenAt: instances.map(\.lastSeenAt).max() ?? 0,
                instances: instances
            )
        }
        return .snapshot(
            PresenceSnapshot(
                teamId: "team",
                now: 0,
                heartbeatIntervalMs: 15_000,
                offlineTimeoutMs: 45_000,
                devices: devices
            )
        )
    }

    @Test func deviceSummaryRollsUpOnlyThatDevicesInstances() {
        var map = PresenceMap()
        map.apply(snapshot([
            instance(deviceId: "mac-a", tag: "default", online: false, lastSeenAt: 1_000),
            instance(deviceId: "mac-a", tag: "presvc", online: true, lastSeenAt: 5_000),
            instance(deviceId: "mac-b", tag: "default", online: false, lastSeenAt: 9_000),
        ]))
        let a = map.deviceSummary(deviceId: "mac-a")
        #expect(a?.online == true)
        #expect(a?.lastSeenAt == Date(timeIntervalSince1970: 5))
        let b = map.deviceSummary(deviceId: "mac-b")
        #expect(b?.online == false)
        #expect(b?.lastSeenAt == Date(timeIntervalSince1970: 9))
        #expect(map.deviceSummary(deviceId: "never-seen") == nil)
    }

    @Test func deviceSummaryCarriesTransportModeFromTheLabelInstance() {
        var map = PresenceMap()
        // Two instances: the ONLINE one's mode must win (it's the build actually
        // running), not the fresher offline one's.
        map.apply(snapshot([
            instance(deviceId: "mac-a", tag: "default", transportMode: "cmuxRelay", online: true, lastSeenAt: 1_000),
            instance(deviceId: "mac-a", tag: "old", transportMode: "tailscale", online: false, lastSeenAt: 9_000),
        ]))
        #expect(map.deviceSummary(deviceId: "mac-a")?.transportMode == "cmuxRelay")
        // A host that never announced a mode yields nil (older Mac build).
        map.apply(snapshot([instance(deviceId: "mac-b", online: true)]))
        #expect(map.deviceSummary(deviceId: "mac-b")?.transportMode == nil)
    }

    @Test func presenceInstanceDecodesTransportModeFromWireJSON() throws {
        // The worker's PresenceInstance JSON shape (workers/presence/src/core.ts)
        // with the transportMode the Mac heartbeats; absent field decodes nil.
        let json = """
        {"deviceId":"d","tag":"default","platform":"mac","capabilities":[],
         "online":true,"lastSeenAt":1000,"transportMode":"ownRelay"}
        """
        let decoded = try JSONDecoder().decode(PresenceInstance.self, from: Data(json.utf8))
        #expect(decoded.transportMode == "ownRelay")
        let legacy = """
        {"deviceId":"d","tag":"default","platform":"mac","capabilities":[],
         "online":true,"lastSeenAt":1000}
        """
        let decodedLegacy = try JSONDecoder().decode(PresenceInstance.self, from: Data(legacy.utf8))
        #expect(decodedLegacy.transportMode == nil)
    }

    @Test func snapshotReplacesTheWholeMap() {
        var map = PresenceMap()
        map.apply(snapshot([instance(deviceId: "mac-a")]))
        map.apply(snapshot([instance(deviceId: "mac-b")]))
        #expect(map.deviceSummary(deviceId: "mac-a") == nil)
        #expect(map.deviceSummary(deviceId: "mac-b") != nil)
    }

    @Test func transitionEventsUpsertSingleInstances() {
        var map = PresenceMap()
        map.apply(snapshot([instance(deviceId: "mac-a", online: true)]))
        map.apply(.offline(instance(deviceId: "mac-a", online: false, lastSeenAt: 2_000), reason: .timeout))
        #expect(map.deviceSummary(deviceId: "mac-a")?.online == false)
        map.apply(.online(instance(deviceId: "mac-a", online: true, lastSeenAt: 3_000)))
        #expect(map.deviceSummary(deviceId: "mac-a")?.online == true)
        // An event for a device the snapshot never carried still lands.
        map.apply(.online(instance(deviceId: "mac-c", online: true)))
        #expect(map.deviceSummary(deviceId: "mac-c")?.online == true)
    }

    @Test func soleRouteAdvertisingInstanceRequiresExactlyOneOnlineRouteBearer() throws {
        let routes = [
            try CmxAttachRoute(id: "r", kind: .tailscale, endpoint: .hostPort(host: "100.0.0.1", port: 51000))
        ]
        var withRoutes = instance(deviceId: "mac-a", tag: "default")
        withRoutes.routes = routes
        var map = PresenceMap()
        map.apply(.online(withRoutes))
        // One online route-bearing instance: unambiguous.
        #expect(map.soleRouteAdvertisingInstance(deviceId: "mac-a")?.tag == "default")
        // A second online route-bearing tag (debug build) makes it ambiguous.
        var debugBuild = instance(deviceId: "mac-a", tag: "presvc")
        debugBuild.routes = routes
        map.apply(.online(debugBuild))
        #expect(map.soleRouteAdvertisingInstance(deviceId: "mac-a") == nil)
        // The debug build going offline restores the single authority.
        debugBuild.online = false
        map.apply(.offline(debugBuild, reason: .goodbye))
        #expect(map.soleRouteAdvertisingInstance(deviceId: "mac-a")?.tag == "default")
        // Online instances without routes never count.
        map.apply(.online(instance(deviceId: "mac-b")))
        #expect(map.soleRouteAdvertisingInstance(deviceId: "mac-b") == nil)
    }

    @Test func seenTickUpdatesLastSeenAndIgnoresUnknownInstances() {
        var map = PresenceMap()
        map.apply(snapshot([instance(deviceId: "mac-a", tag: "default", lastSeenAt: 1_000)]))
        map.apply(.seen(deviceId: "mac-a", tag: "default", lastSeenAt: 7_000))
        #expect(map.instance(deviceId: "mac-a", tag: "default")?.lastSeenAt == 7_000)
        // Unknown (device, tag) ticks are dropped, never create phantom rows.
        map.apply(.seen(deviceId: "mac-a", tag: "ghost", lastSeenAt: 8_000))
        map.apply(.seen(deviceId: "mac-z", tag: "default", lastSeenAt: 8_000))
        #expect(map.instance(deviceId: "mac-a", tag: "ghost") == nil)
        #expect(map.deviceSummary(deviceId: "mac-z") == nil)
    }
}
