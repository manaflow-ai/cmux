import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct CmxSSHTunneledAttachTicketTests {
    @Test func rewritesPreferredRemoteRouteToLocalLoopback() throws {
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-mini",
            macDisplayName: "Mac mini",
            macUserID: "user-1",
            routes: [
                try CmxAttachRoute(
                    id: "tailscale",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "100.64.1.10", port: 58_465),
                    priority: 10
                ),
            ],
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            authToken: "ticket-secret"
        )

        let tunneled = try CmxSSHTunneledAttachTicket(ticket: ticket, localPort: 49_321)

        #expect(tunneled.remoteRoute.id == "tailscale")
        #expect(tunneled.remoteRoute.endpoint == .hostPort(host: "100.64.1.10", port: 58_465))
        #expect(tunneled.ticket.routes == [
            try CmxAttachRoute(
                id: "ssh_tunnel",
                kind: .debugLoopback,
                endpoint: .hostPort(host: "127.0.0.1", port: 49_321),
                priority: 0
            ),
        ])
        #expect(tunneled.ticket.macDeviceID == "mac-mini")
        #expect(tunneled.ticket.macUserID == "user-1")
        #expect(tunneled.ticket.authToken == "ticket-secret")
    }

    @Test func rejectsInvalidLocalPort() throws {
        let ticket = try macTicket(routes: [
            try CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.64.1.10", port: 58_465)
            ),
        ])

        #expect(throws: CmxSSHTunneledAttachTicketError.invalidLocalPort(70_000)) {
            _ = try CmxSSHTunneledAttachTicket(ticket: ticket, localPort: 70_000)
        }
    }

    @Test func rejectsTicketsWithoutForwardableRoutes() throws {
        let ticket = try macTicket(routes: [
            try CmxAttachRoute(
                id: "websocket",
                kind: .websocket,
                endpoint: .url("wss://example.invalid/mobile")
            ),
        ])

        #expect(throws: CmxSSHTunneledAttachTicketError.noForwardableRemoteRoute) {
            _ = try CmxSSHTunneledAttachTicket(ticket: ticket, localPort: 49_321)
        }
    }

    @Test func attachURLEncodesLoopbackTicketThroughCompactFallback() throws {
        let ticket = try macTicket(routes: [
            try CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.64.1.10", port: 58_465)
            ),
        ])
        let tunneled = try CmxSSHTunneledAttachTicket(ticket: ticket, localPort: 49_321)

        let url = try tunneled.attachURL()

        #expect(url.scheme == "cmux-ios")
        #expect(url.host == "attach")
        #expect(url.absoluteString.contains("payload="))
        #expect(!url.absoluteString.contains("100.64.1.10"))
    }

    @Test func attachURLPreservesTokenAndExpiryForTunneledTickets() throws {
        let expiry = Date(timeIntervalSince1970: 4_000_000_000)
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace:1",
            terminalID: "terminal:1",
            macDeviceID: "mac-mini",
            macDisplayName: "Mac mini",
            macUserID: "user-1",
            routes: [
                try CmxAttachRoute(
                    id: "tailscale",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "100.64.1.10", port: 58_465),
                    priority: 10
                ),
            ],
            expiresAt: expiry,
            authToken: "ticket-secret"
        )
        let tunneled = try CmxSSHTunneledAttachTicket(ticket: ticket, localPort: 49_321)

        let payload = try payloadData(from: tunneled.attachURL())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CmxAttachTicket.self, from: payload)

        #expect(decoded.authToken == "ticket-secret")
        #expect(decoded.expiresAt == expiry)
        #expect(decoded.routes == [
            try CmxAttachRoute(
                id: "ssh_tunnel",
                kind: .debugLoopback,
                endpoint: .hostPort(host: "127.0.0.1", port: 49_321),
                priority: 0
            ),
        ])
    }

    private func macTicket(routes: [CmxAttachRoute]) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-mini",
            macDisplayName: "Mac mini",
            routes: routes
        )
    }

    private func payloadData(from url: URL) throws -> Data {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let payload = try #require(components.queryItems?.first { $0.name == "payload" }?.value)
        var base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        return try #require(Data(base64Encoded: base64))
    }
}
