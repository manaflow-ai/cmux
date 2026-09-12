import Foundation
import Testing
@testable import CMUXMobileCore

@Suite
struct CmxNextTransportRouteTests {
    private let canonicalEndpointID = String(repeating: "a", count: 64)

    // MARK: - Next-transport presence advertisement (graduation slice 3)

    @Test func nextTransportRouteAcceptsPeerEndpoint() throws {
        let route = try CmxAttachRoute(
            id: "next_transport",
            kind: .nextTransport,
            endpoint: .peer(
                id: canonicalEndpointID,
                relayHint: nil,
                directAddrs: [],
                relayURL: "https://relay.example.test"
            ),
            priority: 30
        )
        #expect(route.kind == .nextTransport)
        #expect(route.endpoint.irohPeerIdentity?.endpointID == canonicalEndpointID)
    }

    @Test func nextTransportRouteRejectsHostPortEndpoint() throws {
        #expect(throws: CmxAttachRouteError.endpointMismatch(
            kind: .nextTransport,
            endpoint: .hostPort(host: "100.64.1.2", port: 49831)
        )) {
            _ = try CmxAttachRoute(
                id: "next_transport",
                kind: .nextTransport,
                endpoint: .hostPort(host: "100.64.1.2", port: 49831)
            )
        }
    }

    @Test func nextTransportRouteDecodesAlongsideLegacyKinds() throws {
        let data = Data("""
        [
          {
            "id": "iroh",
            "kind": "iroh",
            "endpoint": { "type": "peer", "id": "\(canonicalEndpointID)" },
            "priority": 0
          },
          {
            "id": "tailscale",
            "kind": "tailscale",
            "endpoint": { "type": "host_port", "host": "100.64.1.2", "port": 49831 },
            "priority": 10
          },
          {
            "id": "next_transport",
            "kind": "next_transport",
            "endpoint": {
              "type": "peer",
              "id": "\(canonicalEndpointID)",
              "relay_url": "https://relay.example.test"
            },
            "priority": 30
          }
        ]
        """.utf8)

        let routes = try JSONDecoder().decode([CmxAttachRoute].self, from: data)

        #expect(routes.map(\.kind) == [.iroh, .tailscale, .nextTransport])
        #expect(routes[2].id == "next_transport")
        #expect(routes[2].priority == 30)
    }

    @Test func attachTicketDropsUnknownRouteButKeepsLegacyRoutes() throws {
        let data = Data("""
        {
          "version": 1,
          "workspaceID": "workspace-1",
          "terminalID": null,
          "macDeviceID": "mac-1",
          "routes": [
            {
              "id": "future",
              "kind": "future_transport",
              "endpoint": { "type": "peer", "id": "\(canonicalEndpointID)" }
            },
            {
              "id": "tailscale",
              "kind": "tailscale",
              "endpoint": { "type": "host_port", "host": "100.64.1.2", "port": 49831 }
            }
          ]
        }
        """.utf8)

        let ticket = try JSONDecoder().decode(CmxAttachTicket.self, from: data)
        #expect(ticket.routes.map(\.kind) == [.tailscale])
    }

    @Test func attachTicketStillRejectsMalformedKnownRoute() throws {
        let data = Data("""
        {
          "version": 1,
          "workspaceID": "workspace-1",
          "terminalID": null,
          "macDeviceID": "mac-1",
          "routes": [
            {
              "id": "tailscale",
              "kind": "tailscale",
              "endpoint": { "type": "host_port", "host": "100.64.1.2", "port": 0 }
            }
          ]
        }
        """.utf8)

        #expect(throws: CmxAttachRouteError.invalidPort(0)) {
            _ = try JSONDecoder().decode(CmxAttachTicket.self, from: data)
        }
    }

    @Test func nextTransportRouteIsNeverPreferredByLegacySupportedKinds() throws {
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-1",
            terminalID: nil,
            macDeviceID: "mac-1",
            macDisplayName: nil,
            routes: [
                CmxAttachRoute(
                    id: "next_transport",
                    kind: .nextTransport,
                    endpoint: .peer(
                        id: canonicalEndpointID,
                        relayHint: nil,
                        directAddrs: [],
                        relayURL: nil
                    ),
                    priority: 0
                ),
                CmxAttachRoute(
                    id: "tailscale",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "100.64.1.2", port: 49831),
                    priority: 10
                ),
            ]
        )

        // Legacy clients only ever pass factory-backed kinds; the facade route
        // must never win even though it sorts first by priority.
        #expect(
            ticket.preferredRoute(
                supportedKinds: [.tailscale, .iroh, .websocket, .debugLoopback]
            )?.kind == .tailscale
        )
    }
}
