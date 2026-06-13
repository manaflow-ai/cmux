import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShellModel

/// Behavior of the pure auto-attach target selector: which Mac (or none) a
/// signed-in phone connects to on the "sign in → connected" path. The whole
/// "one obvious Mac, else fall through to manual pair" policy is verified here
/// without any live connection, since the selector is pure.
@Suite struct MobileAutoAttachTargetSelectorTests {
    private static let supported: [CmxAttachTransportKind] = [.tailscale]

    private func route(
        id: String = "tailscale",
        kind: CmxAttachTransportKind = .tailscale,
        host: String = "100.0.0.1",
        port: Int = 58_465,
        priority: Int = 0
    ) -> CmxAttachRoute {
        try! CmxAttachRoute(
            id: id,
            kind: kind,
            endpoint: .hostPort(host: host, port: port),
            priority: priority
        )
    }

    private func device(
        id: String,
        platform: String = "mac",
        lastSeen: Date,
        routes: [CmxAttachRoute]? = nil
    ) -> RegistryDevice {
        let r = routes ?? [route(host: "100.0.0.\(abs(id.hashValue) % 200 + 1)")]
        return RegistryDevice(
            deviceId: id,
            platform: platform,
            displayName: "Mac \(id)",
            lastSeenAt: lastSeen,
            instances: [RegistryAppInstance(tag: "stable", routes: r, lastSeenAt: lastSeen)]
        )
    }

    @Test func singleReachableCandidateIsPickedOnRecency() {
        let now = Date()
        let target = MobileAutoAttachTargetSelector.selectTarget(
            devices: [device(id: "A", lastSeen: now)],
            supportedRouteKinds: Self.supported
        )
        #expect(target?.device.deviceId == "A")
        #expect(target?.instance.tag == "stable")
    }

    @Test func noCandidateWhenNoDevices() {
        #expect(MobileAutoAttachTargetSelector.selectTarget(
            devices: [],
            supportedRouteKinds: Self.supported
        ) == nil)
    }

    @Test func noCandidateWhenNoReachableRoute() {
        let now = Date()
        // Only a websocket route, but client supports only tailscale.
        let wsRoute = try! CmxAttachRoute(id: "ws", kind: .websocket, endpoint: .url("wss://x"))
        let dev = device(id: "A", lastSeen: now, routes: [wsRoute])
        #expect(MobileAutoAttachTargetSelector.selectTarget(
            devices: [dev],
            supportedRouteKinds: Self.supported
        ) == nil)
    }

    @Test func nonControllableHostIsNotACandidate() {
        let now = Date()
        let phone = device(id: "phone", platform: "ios", lastSeen: now)
        #expect(MobileAutoAttachTargetSelector.selectTarget(
            devices: [phone],
            supportedRouteKinds: Self.supported
        ) == nil)
    }

    @Test func onlineDevicePreferredOverMoreRecentOfflineDevice() {
        let now = Date()
        let online = device(id: "online", lastSeen: now.addingTimeInterval(-3600))
        let recentOffline = device(id: "offline", lastSeen: now)
        let target = MobileAutoAttachTargetSelector.selectTarget(
            devices: [recentOffline, online],
            supportedRouteKinds: Self.supported,
            presenceOnlineDeviceIDs: ["online"],
            presenceAvailable: true,
            now: now
        )
        #expect(target?.device.deviceId == "online")
    }

    @Test func multipleOnlineDevicesAreAmbiguousAndYieldNoTarget() {
        let now = Date()
        let a = device(id: "A", lastSeen: now)
        let b = device(id: "B", lastSeen: now.addingTimeInterval(-10))
        #expect(MobileAutoAttachTargetSelector.selectTarget(
            devices: [a, b],
            supportedRouteKinds: Self.supported,
            presenceOnlineDeviceIDs: ["A", "B"],
            presenceAvailable: true,
            now: now
        ) == nil)
    }

    @Test func zeroOnlineFallsBackToRecency() {
        let now = Date()
        let a = device(id: "A", lastSeen: now)
        let b = device(id: "B", lastSeen: now.addingTimeInterval(-3600))
        // Presence available but nobody online: pick the strictly-more-recent one.
        let target = MobileAutoAttachTargetSelector.selectTarget(
            devices: [a, b],
            supportedRouteKinds: Self.supported,
            presenceOnlineDeviceIDs: [],
            presenceAvailable: true,
            now: now
        )
        #expect(target?.device.deviceId == "A")
    }

    @Test func mostRecentWinsWhenNoPresenceSignal() {
        let now = Date()
        let a = device(id: "A", lastSeen: now)
        let b = device(id: "B", lastSeen: now.addingTimeInterval(-60))
        let target = MobileAutoAttachTargetSelector.selectTarget(
            devices: [b, a],
            supportedRouteKinds: Self.supported,
            presenceAvailable: false,
            now: now
        )
        #expect(target?.device.deviceId == "A")
    }

    @Test func equallyRecentNoPresenceIsAmbiguous() {
        let now = Date()
        let a = device(id: "A", lastSeen: now)
        let b = device(id: "B", lastSeen: now)
        #expect(MobileAutoAttachTargetSelector.selectTarget(
            devices: [a, b],
            supportedRouteKinds: Self.supported,
            presenceAvailable: false,
            now: now
        ) == nil)
    }

    @Test func picksFreshestReachableInstanceWithinADevice() {
        let now = Date()
        let stale = RegistryAppInstance(
            tag: "old",
            routes: [route(id: "r-old")],
            lastSeenAt: now.addingTimeInterval(-3600)
        )
        let fresh = RegistryAppInstance(
            tag: "new",
            routes: [route(id: "r-new")],
            lastSeenAt: now
        )
        let dev = RegistryDevice(
            deviceId: "A",
            platform: "mac",
            displayName: "Mac",
            lastSeenAt: now,
            instances: [stale, fresh]
        )
        let target = MobileAutoAttachTargetSelector.selectTarget(
            devices: [dev],
            supportedRouteKinds: Self.supported
        )
        #expect(target?.instance.tag == "new")
    }

    @Test func rejectLoopbackSkipsLoopbackOnlyDevicesForPhysicalPhone() {
        let now = Date()
        // A device that only advertises a loopback debugLoopback route.
        let loopback = try! CmxAttachRoute(
            id: "loop",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let dev = device(id: "A", lastSeen: now, routes: [loopback])
        let kinds: [CmxAttachTransportKind] = [.debugLoopback, .tailscale]

        // Simulator (rejectLoopback false): loopback IS the host Mac → candidate.
        #expect(MobileAutoAttachTargetSelector.selectTarget(
            devices: [dev],
            supportedRouteKinds: kinds,
            rejectLoopback: false,
            now: now
        )?.device.deviceId == "A")

        // Physical phone (rejectLoopback true): loopback names the phone itself →
        // not a candidate → fall through to manual.
        #expect(MobileAutoAttachTargetSelector.selectTarget(
            devices: [dev],
            supportedRouteKinds: kinds,
            rejectLoopback: true,
            now: now
        ) == nil)
    }

    @Test func rejectLoopbackStillPicksTailscaleRouteForPhysicalPhone() {
        let now = Date()
        let loopback = try! CmxAttachRoute(
            id: "loop",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584),
            priority: 0
        )
        let tailscale = try! CmxAttachRoute(
            id: "ts",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.0.5", port: 56_584),
            priority: 1
        )
        // Loopback sorts first by priority, but a physical phone must skip it and
        // still reach the Mac on its Tailscale route.
        let dev = device(id: "A", lastSeen: now, routes: [loopback, tailscale])
        let target = MobileAutoAttachTargetSelector.selectTarget(
            devices: [dev],
            supportedRouteKinds: [.debugLoopback, .tailscale],
            rejectLoopback: true,
            now: now
        )
        #expect(target?.device.deviceId == "A")
    }

    @Test func equallyRecentReachableInstancesOnOneDeviceAreAmbiguous() {
        let now = Date()
        // Two reachable tagged builds on one device, tied on lastSeenAt: no
        // obvious build to auto-attach to → no candidate → fall through.
        let a = RegistryAppInstance(tag: "stable", routes: [route(id: "r-a")], lastSeenAt: now)
        let b = RegistryAppInstance(tag: "dev", routes: [route(id: "r-b")], lastSeenAt: now)
        let dev = RegistryDevice(
            deviceId: "A",
            platform: "mac",
            displayName: "Mac",
            lastSeenAt: now,
            instances: [a, b]
        )
        #expect(MobileAutoAttachTargetSelector.selectTarget(
            devices: [dev],
            supportedRouteKinds: Self.supported
        ) == nil)
    }
}
