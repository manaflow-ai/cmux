import CMUXMobileCore
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

    private func peerRoute(
        routeID: String = "iroh",
        peerID: String = "peer-1",
        relayHint: String? = nil,
        directAddrs: [String] = [],
        relayURL: String? = nil,
        priority: Int = 0
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: routeID,
            kind: .iroh,
            endpoint: .peer(
                id: peerID,
                relayHint: relayHint,
                directAddrs: directAddrs,
                relayURL: relayURL
            ),
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

    @Test func differentRegistryRoutesReplaceLocal() throws {
        // The Mac moved networks / changed port: the registry has the current
        // route, which is authoritative and replaces the stale local one for the
        // next dial (the single-dial reconnect path must not be left holding a
        // dead address).
        let local = [try route(host: "100.0.0.1", port: 51000, id: "old")]
        let registry = [try route(host: "100.9.9.9", port: 51999, id: "new")]
        let selected = try #require(
            DeviceRegistryService.selectReconnectRoutes(local: local, registry: registry)
        )
        #expect(selected.count == 1)
        if case let .hostPort(host, _) = selected.first?.endpoint {
            #expect(host == "100.9.9.9")
        } else {
            Issue.record("expected a host_port route")
        }
    }

    @Test func registryMetadataChangeOnSharedEndpointIsWritten() throws {
        // The registry re-advertises an endpoint already cached, but with a
        // changed priority. The endpoint is unchanged, yet the metadata changed,
        // so the full-equality no-op check writes the update — otherwise the
        // phone keeps dialing in the server's stale preferred order indefinitely.
        let cached = try route(host: "100.96.0.9", port: 51000, id: "tailnet", priority: 0)
        let updated = try route(host: "100.96.0.9", port: 51000, id: "tailnet", priority: 9)
        let selected = DeviceRegistryService.selectReconnectRoutes(local: [cached], registry: [updated])
        #expect(selected?.count == 1)
        #expect(selected?.first?.priority == 9)
    }

    @Test func registryPeerEndpointMetadataChangeIsWritten() throws {
        // Peer routes dedup by peer id, but relay/direct-address metadata is
        // still authoritative reachability data and must be persisted when the
        // registry refreshes it.
        let cached = try peerRoute(
            relayHint: "old-relay",
            directAddrs: ["/ip4/10.0.0.1/tcp/51000"],
            relayURL: "wss://relay-old.example"
        )
        let updated = try peerRoute(
            relayHint: "new-relay",
            directAddrs: ["/ip4/10.0.0.2/tcp/51000"],
            relayURL: "wss://relay-new.example"
        )
        let selected = DeviceRegistryService.selectReconnectRoutes(local: [cached], registry: [updated])
        #expect(selected == [updated])
    }

    @Test func registryResponseReplacesLocalEvenIfNarrower() throws {
        // Registry is authoritative when reachable: even a narrower response
        // replaces the cached set for dialing (the registry re-adds routes as the
        // Mac republishes). Retaining the dropped local route as a fallback needs
        // the candidate-iterating follow-up; the single-dial path stays
        // registry-led so it never dials a stale cached address.
        let lan = try route(host: "192.168.1.50", port: 51000, id: "lan")
        let tailnet = try route(host: "100.96.0.9", port: 51999, id: "tailnet")
        let selected = DeviceRegistryService.selectReconnectRoutes(
            local: [lan, tailnet],
            registry: [tailnet]
        )
        #expect(selected?.count == 1)
        #expect(selected?.first?.id == "tailnet")
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
