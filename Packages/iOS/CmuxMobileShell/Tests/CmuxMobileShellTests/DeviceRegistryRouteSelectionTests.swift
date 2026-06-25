import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Tests the pure reconnect-route policy and registry-response parsing. These
/// are the heart of the auto-pair-on-reload path: the policy decides when a
/// stale-route Mac is rescued by registry routes versus when the locally
/// persisted routes win (so pairing survives the registry being down).
@Suite struct DeviceRegistryRouteSelectionTests {
    private func route(host: String, port: Int, id: String = "r", priority: Int = 0) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port),
            priority: priority
        )
    }

    @Test func registryUnavailableFallsBackToLocal() throws {
        let local = [try route(host: "100.0.0.1", port: 51000)]
        // nil == registry unreachable / unauthorized / Mac not registered.
        #expect(DeviceRegistryService.selectReconnectRoutes(local: local, registry: nil) == nil)
    }

    @Test func registryEmptyFallsBackToLocal() throws {
        let local = [try route(host: "100.0.0.1", port: 51000)]
        #expect(DeviceRegistryService.selectReconnectRoutes(local: local, registry: []) == nil)
    }

    @Test func identicalRegistryRoutesAreANoOp() throws {
        let routes = [try route(host: "100.0.0.1", port: 51000)]
        #expect(DeviceRegistryService.selectReconnectRoutes(local: routes, registry: routes) == nil)
    }

    @Test func differentRegistryRoutesWin() throws {
        // The Mac moved networks / changed port: registry has the current route.
        let local = [try route(host: "100.0.0.1", port: 51000)]
        let registry = [try route(host: "100.9.9.9", port: 51999)]
        let selected = DeviceRegistryService.selectReconnectRoutes(local: local, registry: registry)
        #expect(selected == registry)
    }

    @MainActor
    @Test func registryRoutesRescueUnsupportedLocalReconnectRoute() throws {
        let local = [
            try CmxAttachRoute(
                id: "loopback",
                kind: .debugLoopback,
                endpoint: .hostPort(host: "127.0.0.1", port: 51000),
                priority: 0
            ),
        ]
        let registry = [try route(host: "100.9.9.9", port: 51999)]

        let resolved = MobileShellComposite.validatedReconnectRoutes(
            local: local,
            registry: registry,
            supportedKinds: [.tailscale],
            preferNonLoopback: true
        )
        let reachable = MobileShellComposite.firstReconnectHostPortRoute(
            resolved,
            supportedKinds: [.tailscale],
            preferNonLoopback: true
        )

        #expect(reachable?.0 == "100.9.9.9")
        #expect(reachable?.1 == 51999)
    }

    @MainActor
    @Test func unsupportedRegistryRoutesDoNotReplaceReachableLocalRoute() throws {
        let local = [try route(host: "100.0.0.1", port: 51000)]
        let registry = [
            try CmxAttachRoute(
                id: "websocket",
                kind: .websocket,
                endpoint: .url("wss://example.invalid/cmux"),
                priority: 0
            ),
        ]

        let resolved = MobileShellComposite.validatedReconnectRoutes(
            local: local,
            registry: registry,
            supportedKinds: [.tailscale],
            preferNonLoopback: true
        )

        #expect(resolved == local)
    }

    @MainActor
    @Test func loopbackOnlyLocalRouteRefreshesBeforePhysicalDial() throws {
        let loopback = [
            try CmxAttachRoute(
                id: "loopback",
                kind: .debugLoopback,
                endpoint: .hostPort(host: "127.0.0.1", port: 51000),
                priority: 0
            ),
        ]
        let realRoute = [try route(host: "100.0.0.1", port: 51000)]

        #expect(MobileShellComposite.shouldRefreshReconnectRoutesBeforeDial(
            local: loopback,
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        ))
        #expect(!MobileShellComposite.shouldRefreshReconnectRoutesBeforeDial(
            local: loopback,
            supportedKinds: [.debugLoopback],
            preferNonLoopback: false
        ))
        #expect(!MobileShellComposite.shouldRefreshReconnectRoutesBeforeDial(
            local: realRoute,
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        ))
    }

    @Test func parsesRoutesForMatchingMacFromListResponse() throws {
        let json = """
        {
          "teamId": "team-a",
          "devices": [
            {
              "deviceId": "AAAA1111-1111-4111-8111-111111111111",
              "platform": "mac",
              "displayName": "Other Mac",
              "instances": [{ "tag": "stable", "routes": [] }]
            },
            {
              "deviceId": "BBBB2222-2222-4222-8222-222222222222",
              "platform": "mac",
              "displayName": "Lawrence's Mac",
              "instances": [
                { "tag": "stale", "routes": [] },
                {
                  "tag": "stable",
                  "routes": [
                    { "id": "r1", "kind": "tailscale", "priority": 0,
                      "endpoint": { "type": "host_port", "host": "100.9.9.9", "port": 51999 } }
                  ]
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        // Case-insensitive id match (the wire id may be upper- or lower-cased).
        let routes = DeviceRegistryService.routes(
            forMacDeviceID: "bbbb2222-2222-4222-8222-222222222222",
            in: json
        )
        #expect(routes?.count == 1)
        if case let .hostPort(host, port) = routes?.first?.endpoint {
            #expect(host == "100.9.9.9")
            #expect(port == 51999)
        } else {
            Issue.record("expected a host_port route")
        }
    }

    @Test func returnsNilWhenMacNotInListResponse() {
        let json = #"{ "teamId": "team-a", "devices": [] }"#.data(using: .utf8)!
        #expect(DeviceRegistryService.routes(forMacDeviceID: "missing", in: json) == nil)
    }

    @Test func multipleNonEmptyInstancesReturnNilToAvoidWrongTag() {
        // A Mac running two tagged builds (stable + debug), both advertising
        // routes. Without a tag to match, substituting either could connect the
        // phone to the wrong app, so fall back to local routes (nil).
        let json = """
        {
          "teamId": "team-a",
          "devices": [
            {
              "deviceId": "BBBB2222-2222-4222-8222-222222222222",
              "platform": "mac",
              "instances": [
                { "tag": "stable", "routes": [
                  { "id": "r1", "kind": "tailscale", "priority": 0,
                    "endpoint": { "type": "host_port", "host": "100.1.1.1", "port": 51001 } }
                ] },
                { "tag": "debug", "routes": [
                  { "id": "r2", "kind": "tailscale", "priority": 0,
                    "endpoint": { "type": "host_port", "host": "100.2.2.2", "port": 51002 } }
                ] }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        #expect(DeviceRegistryService.routes(
            forMacDeviceID: "bbbb2222-2222-4222-8222-222222222222",
            in: json
        ) == nil)
    }

    @Test func singleNonEmptyInstanceAmongEmptyOnesIsUsed() throws {
        // Multiple instances but only one advertising routes (e.g. stable on,
        // a debug build that turned pairing off): use the single non-empty one.
        let json = """
        {
          "teamId": "team-a",
          "devices": [
            {
              "deviceId": "BBBB2222-2222-4222-8222-222222222222",
              "platform": "mac",
              "instances": [
                { "tag": "debug", "routes": [] },
                { "tag": "stable", "routes": [
                  { "id": "r1", "kind": "tailscale", "priority": 0,
                    "endpoint": { "type": "host_port", "host": "100.1.1.1", "port": 51001 } }
                ] }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let routes = DeviceRegistryService.routes(
            forMacDeviceID: "bbbb2222-2222-4222-8222-222222222222",
            in: json
        )
        #expect(routes?.count == 1)
    }

    @Test func malformedSiblingRouteDoesNotPoisonTheList() throws {
        // One instance has a malformed/unknown route; the target Mac's own valid
        // route must still parse (a bad sibling must not nil the whole response).
        let json = """
        {
          "teamId": "team-a",
          "devices": [
            {
              "deviceId": "AAAA1111-1111-4111-8111-111111111111",
              "platform": "mac",
              "instances": [
                { "tag": "stable", "routes": [
                  { "id": "bad", "kind": "unknown_future_kind", "endpoint": { "type": "???" } }
                ] }
              ]
            },
            {
              "deviceId": "BBBB2222-2222-4222-8222-222222222222",
              "platform": "mac",
              "instances": [
                { "tag": "stable", "routes": [
                  { "id": "r1", "kind": "tailscale", "priority": 0,
                    "endpoint": { "type": "host_port", "host": "100.9.9.9", "port": 51999 } }
                ] }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let routes = DeviceRegistryService.routes(
            forMacDeviceID: "bbbb2222-2222-4222-8222-222222222222",
            in: json
        )
        #expect(routes?.count == 1)
    }

    @Test func malformedRouteWithinTargetInstanceIsSkipped() throws {
        // A bad route mixed with a good one in the target's own instance: keep
        // the good one, drop the bad one.
        let json = """
        {
          "teamId": "team-a",
          "devices": [
            {
              "deviceId": "BBBB2222-2222-4222-8222-222222222222",
              "platform": "mac",
              "instances": [
                { "tag": "stable", "routes": [
                  { "id": "bad", "kind": "tailscale", "endpoint": { "type": "host_port", "host": "", "port": 0 } },
                  { "id": "good", "kind": "tailscale", "priority": 0,
                    "endpoint": { "type": "host_port", "host": "100.9.9.9", "port": 51999 } }
                ] }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let routes = DeviceRegistryService.routes(
            forMacDeviceID: "bbbb2222-2222-4222-8222-222222222222",
            in: json
        )
        #expect(routes?.count == 1)
        #expect(routes?.first?.id == "good")
    }

    @Test func extractsRoutesFromDecodedRegistryDevices() throws {
        let routes = [try route(host: "100.9.9.9", port: 51999, id: "fresh")]
        let devices = [
            RegistryDevice(
                deviceId: "mac-a",
                platform: "mac",
                displayName: "A",
                lastSeenAt: .distantPast,
                instances: [
                    RegistryAppInstance(tag: "old", routes: [], lastSeenAt: .distantPast),
                    RegistryAppInstance(tag: "stable", routes: routes, lastSeenAt: .distantPast),
                ]
            ),
            RegistryDevice(
                deviceId: "mac-b",
                platform: "mac",
                displayName: "B",
                lastSeenAt: .distantPast,
                instances: [
                    RegistryAppInstance(
                        tag: "stable",
                        routes: [try route(host: "100.0.0.2", port: 51000, id: "other")],
                        lastSeenAt: .distantPast
                    ),
                ]
            ),
        ]

        #expect(DeviceRegistryService.routes(forMacDeviceID: "mac-a", in: devices) == routes)
        #expect(DeviceRegistryService.routes(in: devices[0]) == routes)
    }

    @Test func appliesRefreshWhenStillSignedInSameUserSameActiveMac() {
        #expect(DeviceRegistryService.shouldApplyRegistryRefresh(
            isSignedIn: true,
            capturedUserID: "user-1",
            currentUserID: "user-1",
            activeMacID: "mac-1",
            targetMacID: "mac-1"
        ) == true)
    }

    @Test func rejectsRefreshAfterSignOut() {
        // User signed out while freshRoutes was in flight: never resurrect.
        #expect(DeviceRegistryService.shouldApplyRegistryRefresh(
            isSignedIn: false,
            capturedUserID: "user-1",
            currentUserID: nil,
            activeMacID: nil,
            targetMacID: "mac-1"
        ) == false)
    }

    @Test func rejectsRefreshAfterUserSwitch() {
        #expect(DeviceRegistryService.shouldApplyRegistryRefresh(
            isSignedIn: true,
            capturedUserID: "user-1",
            currentUserID: "user-2",
            activeMacID: "mac-1",
            targetMacID: "mac-1"
        ) == false)
    }

    @Test func rejectsRefreshAfterMacForgotten() {
        // The Mac was forgotten (no active Mac now): do not recreate it.
        #expect(DeviceRegistryService.shouldApplyRegistryRefresh(
            isSignedIn: true,
            capturedUserID: "user-1",
            currentUserID: "user-1",
            activeMacID: nil,
            targetMacID: "mac-1"
        ) == false)
    }

    @Test func rejectsRefreshAfterActiveMacSwitched() {
        // The user switched to a different active Mac (e.g. rescanned a QR):
        // do not reactivate the old one.
        #expect(DeviceRegistryService.shouldApplyRegistryRefresh(
            isSignedIn: true,
            capturedUserID: "user-1",
            currentUserID: "user-1",
            activeMacID: "mac-2",
            targetMacID: "mac-1"
        ) == false)
    }

    @Test func deviceIdentityPersistsAcrossLookups() {
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = DeviceRegistryService.deviceID(defaults: defaults)
        let second = DeviceRegistryService.deviceID(defaults: defaults)
        #expect(first == second)
        #expect(!first.isEmpty)
        // Stable across a fresh accessor reading the same store (relaunch proxy).
        #expect(UUID(uuidString: first) != nil)
    }
}
