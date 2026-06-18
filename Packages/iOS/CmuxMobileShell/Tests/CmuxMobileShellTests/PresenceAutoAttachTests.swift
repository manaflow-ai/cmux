import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

/// Behavior tests for presence-driven auto-attach: the production-isolation flag
/// and the pure target-selection that turns the live presence map into the one
/// host the phone should auto-connect to.
@MainActor
@Suite struct PresenceAutoAttachTests {
    // MARK: Flag (production isolation)

    @Test func flagDefaultsToBuildTypeWhenNoOverride() {
        let on = MobilePresenceAutoAttachFlag(environment: [:], defaults: nil, isDebugBuild: true)
        let off = MobilePresenceAutoAttachFlag(environment: [:], defaults: nil, isDebugBuild: false)
        #expect(on.isEnabled)
        #expect(!off.isEnabled)  // Release default OFF: production never auto-attaches.
    }

    @Test func envOverrideWinsBothDirections() {
        // Env can force it on in a (would-be) Release build, or off in DEBUG.
        let forcedOn = MobilePresenceAutoAttachFlag(
            environment: ["CMUX_PRESENCE_AUTO_ATTACH": "1"], defaults: nil, isDebugBuild: false)
        let forcedOff = MobilePresenceAutoAttachFlag(
            environment: ["CMUX_PRESENCE_AUTO_ATTACH": "0"], defaults: nil, isDebugBuild: true)
        #expect(forcedOn.isEnabled)
        #expect(!forcedOff.isEnabled)
    }

    @Test func userDefaultsOverridesBuildDefault() {
        let suite = UserDefaults(suiteName: "presence-auto-attach-test-\(UUID().uuidString)")!
        suite.set(false, forKey: MobilePresenceAutoAttachFlag.defaultsKey)
        let flag = MobilePresenceAutoAttachFlag(environment: [:], defaults: suite, isDebugBuild: true)
        #expect(!flag.isEnabled)  // explicit opt-out honored even in DEBUG
    }

    // MARK: Target selection

    private func instance(
        deviceId: String,
        platform: String = "mac",
        online: Bool = true,
        lastSeenAt: Double,
        hasRoute: Bool = true
    ) -> PresenceInstance {
        let routes: [CmxAttachRoute]? = hasRoute
            ? [try! CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.64.0.\(abs(deviceId.hashValue) % 250 + 1)", port: 50879))]
            : nil
        return PresenceInstance(
            deviceId: deviceId, tag: "default", platform: platform,
            online: online, lastSeenAt: lastSeenAt, routes: routes)
    }

    private func map(_ instances: [PresenceInstance]) -> PresenceMap {
        var m = PresenceMap()
        for i in instances { m.apply(.online(i)) }
        return m
    }

    @Test func picksFreshestOnlineHostWithADialableRoute() {
        let m = map([
            instance(deviceId: "mac-a", lastSeenAt: 5_000),
            instance(deviceId: "mac-b", lastSeenAt: 9_000),            // freshest eligible
            instance(deviceId: "mac-c", lastSeenAt: 12_000, hasRoute: false), // no route
            instance(deviceId: "ios-x", platform: "ios", lastSeenAt: 99_000), // a phone
            instance(deviceId: "mac-d", online: false, lastSeenAt: 99_000),    // offline
        ])
        let target = MobileShellComposite.presenceAutoAttachTarget(in: m, supportedKinds: [])
        #expect(target?.deviceId == "mac-b")
    }

    @Test func returnsNilWhenNoEligibleHost() {
        #expect(MobileShellComposite.presenceAutoAttachTarget(in: PresenceMap(), supportedKinds: []) == nil)
        let onlyPhonesAndOffline = map([
            instance(deviceId: "ios-x", platform: "ios", lastSeenAt: 9_000),
            instance(deviceId: "mac-d", online: false, lastSeenAt: 9_000),
            instance(deviceId: "mac-e", lastSeenAt: 9_000, hasRoute: false),
        ])
        #expect(MobileShellComposite.presenceAutoAttachTarget(in: onlyPhonesAndOffline, supportedKinds: []) == nil)
    }

    @Test func unsupportedRouteKindIsNotDialable() {
        // A host whose only route kind is not in the supported set is skipped.
        let m = map([instance(deviceId: "mac-a", lastSeenAt: 9_000)]) // tailscale route
        #expect(MobileShellComposite.presenceAutoAttachTarget(in: m, supportedKinds: [.websocket]) == nil)
        #expect(MobileShellComposite.presenceAutoAttachTarget(in: m, supportedKinds: [.tailscale])?.deviceId == "mac-a")
    }
}
