import Foundation
import Testing
@testable import CMUXMobileCore

/// Coverage for the Cloud VM attach path: decoding the backend
/// `POST /api/vm/{id}/attach-endpoint` response and turning it into a
/// ``CmxAttachTicket`` that reuses the same route model a paired Mac uses
/// (issue #6700).
@Suite struct CmxCloudAttachTests {
    /// A header-less Freestyle-style WebSocket response (the default provider;
    /// it authorizes by token alone) with both the terminal PTY lease and the
    /// cmuxd-remote daemon lease. Mirrors `WebSocketPtyEndpoint` in
    /// `web/services/vms/drivers/types.ts`. This is the shape `ticket(from:)`
    /// accepts.
    private func freestyleResponseJSON(
        terminalURL: String = "wss://vm-123.vm.freestyle.sh/terminal",
        terminalToken: String = "cmux-freestyle-pty-aaaa",
        daemonURL: String = "wss://vm-123.vm.freestyle.sh/rpc",
        daemonToken: String = "cmux-freestyle-rpc-bbbb",
        daemonExpiresAtUnix: Double = 1_900_000_000
    ) -> String {
        """
        {
          "transport": "websocket",
          "url": "\(terminalURL)",
          "headers": {},
          "token": "\(terminalToken)",
          "sessionId": "sess-pty-1",
          "expiresAtUnix": 1899999000,
          "daemon": {
            "url": "\(daemonURL)",
            "headers": {},
            "token": "\(daemonToken)",
            "sessionId": "sess-rpc-1",
            "expiresAtUnix": \(daemonExpiresAtUnix)
          }
        }
        """
    }

    /// An E2B-style response: every lease carries the `e2b-traffic-access-token`
    /// handshake header the brokered upgrade requires (`drivers/e2b.ts`). The
    /// endpoint decodes fine, but `ticket(from:)` refuses it because the route
    /// model cannot yet carry per-lease headers.
    private func e2bResponseJSON() -> String {
        """
        {
          "transport": "websocket",
          "url": "wss://7777-sandbox.e2b.app/terminal",
          "headers": { "e2b-traffic-access-token": "tok-pty" },
          "token": "cmux-e2b-pty-aaaa",
          "sessionId": "sess-pty-1",
          "expiresAtUnix": 1899999000,
          "daemon": {
            "url": "wss://7777-sandbox.e2b.app/rpc",
            "headers": { "e2b-traffic-access-token": "tok-rpc" },
            "token": "cmux-e2b-rpc-bbbb",
            "sessionId": "sess-rpc-1",
            "expiresAtUnix": 1900000000
          }
        }
        """
    }

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    // MARK: - Decoding

    @Test func decodesTerminalAndDaemonLeases() throws {
        let endpoint = try CmxCloudAttach().decode(data(freestyleResponseJSON()))

        #expect(endpoint.transport == "websocket")
        #expect(endpoint.terminal.url == "wss://vm-123.vm.freestyle.sh/terminal")
        #expect(endpoint.terminal.token == "cmux-freestyle-pty-aaaa")
        #expect(endpoint.terminal.sessionID == "sess-pty-1")
        #expect(endpoint.terminal.expiresAtUnix == 1_899_999_000)
        #expect(endpoint.terminal.headers.isEmpty)

        let daemon = try #require(endpoint.daemon)
        #expect(daemon.url == "wss://vm-123.vm.freestyle.sh/rpc")
        #expect(daemon.token == "cmux-freestyle-rpc-bbbb")
        #expect(daemon.sessionID == "sess-rpc-1")
        #expect(daemon.expiresAtUnix == 1_900_000_000)
        #expect(daemon.headers.isEmpty)
    }

    @Test func decodePreservesHandshakeHeaders() throws {
        // Decoding is faithful: an E2B endpoint keeps its headers on the model
        // even though `ticket(from:)` later refuses to build a route from it.
        let endpoint = try CmxCloudAttach().decode(data(e2bResponseJSON()))
        #expect(endpoint.terminal.headers["e2b-traffic-access-token"] == "tok-pty")
        #expect(endpoint.daemon?.headers["e2b-traffic-access-token"] == "tok-rpc")
    }

    @Test func decodesEndpointWithoutDaemon() throws {
        let json = """
        {
          "transport": "websocket",
          "url": "wss://vm-9.vm.freestyle.sh/terminal",
          "headers": {},
          "token": "cmux-freestyle-pty-only",
          "sessionId": "sess-pty-only",
          "expiresAtUnix": 1899999000
        }
        """
        let endpoint = try CmxCloudAttach().decode(data(json))
        #expect(endpoint.terminal.token == "cmux-freestyle-pty-only")
        #expect(endpoint.terminal.headers.isEmpty)
        #expect(endpoint.daemon == nil)
    }

    @Test func decodeRejectsSSHTransport() {
        // The SSH fallback has a different shape (host/port/credential) and the
        // phone cannot dial it; it must surface as a typed transport error, not
        // an opaque decode failure.
        let json = """
        {
          "transport": "ssh",
          "host": "vm-ssh.freestyle.sh",
          "port": 22,
          "username": "cmux",
          "publicKeyFingerprint": null,
          "credential": { "kind": "password", "value": "one-time" },
          "identityHandle": "identity-1"
        }
        """
        #expect(throws: CmxCloudAttachError.unsupportedTransport("ssh")) {
            _ = try CmxCloudAttach().decode(data(json))
        }
    }

    @Test func roundTripsEndpointWithHeaders() throws {
        // The header-bearing path exercises the headers encode branch.
        let endpoint = try CmxCloudAttach().decode(data(e2bResponseJSON()))
        let encoded = try JSONEncoder().encode(endpoint)
        let reDecoded = try JSONDecoder().decode(CmxCloudAttachEndpoint.self, from: encoded)
        #expect(reDecoded == endpoint)
    }

    @Test func roundTripsEndpointWithoutHeaders() throws {
        let endpoint = try CmxCloudAttach().decode(data(freestyleResponseJSON()))
        let encoded = try JSONEncoder().encode(endpoint)
        let reDecoded = try JSONDecoder().decode(CmxCloudAttachEndpoint.self, from: encoded)
        #expect(reDecoded == endpoint)
        // Empty headers are omitted from the encoded form, not written as `{}`.
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["headers"] == nil)
    }

    // MARK: - Ticket construction

    @Test func ticketCarriesWebSocketRouteToDaemon() throws {
        let endpoint = try CmxCloudAttach().decode(data(freestyleResponseJSON()))
        let ticket = try CmxCloudAttach().ticket(
            from: endpoint,
            displayName: "Reviewer Cloud VM",
            macUserID: "stack-user-appreview"
        )

        // Single cloud route: the cmuxd-remote daemon, reached over WebSocket.
        #expect(ticket.routes.count == 1)
        let route = try #require(ticket.routes.first)
        #expect(route.id == "cloud_rpc")
        #expect(route.kind == .websocket)
        #expect(route.endpoint == .url("wss://vm-123.vm.freestyle.sh/rpc"))
        #expect(route.priority == 10)

        // The lease token and expiry ride the ticket (unlike the Mac QR).
        #expect(ticket.authToken == "cmux-freestyle-rpc-bbbb")
        #expect(ticket.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))

        // Unscoped, identity-less — exactly like a scanned pairing ticket; the
        // host identity is recovered post-handshake from mobile.host.status.
        #expect(ticket.workspaceID == "")
        #expect(ticket.terminalID == nil)
        #expect(ticket.macDeviceID == "")
        #expect(ticket.macDisplayName == "Reviewer Cloud VM")
        #expect(ticket.macUserID == "stack-user-appreview")
        #expect(ticket.macUserEmail == nil)
    }

    @Test func ticketDefaultsCarryNoIdentityHints() throws {
        let endpoint = try CmxCloudAttach().decode(data(freestyleResponseJSON()))
        let ticket = try CmxCloudAttach().ticket(from: endpoint)
        #expect(ticket.macDisplayName == nil)
        #expect(ticket.macUserID == nil)
        #expect(ticket.authToken == "cmux-freestyle-rpc-bbbb")
    }

    @Test func ticketPrefersWebSocketRouteAndRejectsTailscaleOnly() throws {
        let endpoint = try CmxCloudAttach().decode(data(freestyleResponseJSON()))
        let ticket = try CmxCloudAttach().ticket(from: endpoint)

        // A client that speaks WebSocket reaches the cloud VM...
        let preferred = try #require(ticket.preferredRoute(supportedKinds: [.websocket]))
        #expect(preferred.kind == .websocket)
        // ...but a Tailscale-only client (the Mac path) cannot: a cloud ticket
        // offers no Tailscale route.
        #expect(ticket.preferredRoute(supportedKinds: [.tailscale]) == nil)
    }

    @Test func ticketExpiryDrivesIsExpired() throws {
        let endpoint = try CmxCloudAttach().decode(
            data(freestyleResponseJSON(daemonExpiresAtUnix: 1_900_000_000))
        )
        let ticket = try CmxCloudAttach().ticket(from: endpoint)
        #expect(ticket.isExpired(at: Date(timeIntervalSince1970: 1_899_999_999)) == false)
        #expect(ticket.isExpired(at: Date(timeIntervalSince1970: 1_900_000_001)) == true)
    }

    @Test func ticketTreatsNonPositiveExpiryAsNeverExpiring() throws {
        // A missing/zero lease expiry must not pin the ticket to the 1970 epoch
        // (which would make it instantly expired); it should be non-expiring.
        let endpoint = try CmxCloudAttach().decode(
            data(freestyleResponseJSON(daemonExpiresAtUnix: 0))
        )
        let ticket = try CmxCloudAttach().ticket(from: endpoint)
        #expect(ticket.expiresAt == nil)
        #expect(ticket.isExpired(at: Date(timeIntervalSince1970: 4_000_000_000)) == false)
    }

    @Test func ticketFromResponseDecodesAndBuilds() throws {
        let ticket = try CmxCloudAttach().ticket(
            fromResponse: data(freestyleResponseJSON()),
            displayName: "VM",
            macUserID: "u-1"
        )
        #expect(ticket.routes.first?.endpoint == .url("wss://vm-123.vm.freestyle.sh/rpc"))
        #expect(ticket.authToken == "cmux-freestyle-rpc-bbbb")
    }

    // MARK: - Ticket errors

    @Test func ticketRejectsHeaderBearingDaemonLease() throws {
        // E2B requires per-lease handshake headers the route model cannot carry;
        // building a route would silently drop them, so it is refused outright.
        let endpoint = try CmxCloudAttach().decode(data(e2bResponseJSON()))
        #expect(throws: CmxCloudAttachError.unsupportedHandshakeHeaders(["e2b-traffic-access-token"])) {
            _ = try CmxCloudAttach().ticket(from: endpoint)
        }
    }

    @Test func ticketThrowsWhenDaemonMissing() throws {
        let endpoint = CmxCloudAttachEndpoint(
            terminal: .init(
                url: "wss://vm-9.vm.freestyle.sh/terminal",
                token: "pty-only",
                sessionID: "s",
                expiresAtUnix: 1_900_000_000
            ),
            daemon: nil
        )
        #expect(throws: CmxCloudAttachError.missingDaemon) {
            _ = try CmxCloudAttach().ticket(from: endpoint)
        }
    }

    @Test func ticketThrowsOnUnsupportedTransport() {
        let endpoint = CmxCloudAttachEndpoint(
            transport: "ssh",
            terminal: .init(url: "wss://x/terminal", token: "t", sessionID: "s", expiresAtUnix: 1),
            daemon: .init(url: "wss://x/rpc", token: "t", sessionID: "s", expiresAtUnix: 1)
        )
        #expect(throws: CmxCloudAttachError.unsupportedTransport("ssh")) {
            _ = try CmxCloudAttach().ticket(from: endpoint)
        }
    }

    @Test func ticketThrowsOnNonWebSocketDaemonURL() {
        let endpoint = CmxCloudAttachEndpoint(
            terminal: .init(url: "wss://x/terminal", token: "t", sessionID: "s", expiresAtUnix: 1),
            daemon: .init(url: "https://x/rpc", token: "t", sessionID: "s", expiresAtUnix: 1)
        )
        #expect(throws: CmxCloudAttachError.invalidDaemonURL("https://x/rpc")) {
            _ = try CmxCloudAttach().ticket(from: endpoint)
        }
    }

    @Test func ticketThrowsOnPlaintextWebSocketDaemonURL() {
        // The daemon route carries a bearer token, so a plaintext ws:// endpoint
        // (which would leak it) is refused even though it is a WebSocket URL.
        let endpoint = CmxCloudAttachEndpoint(
            terminal: .init(url: "wss://x/terminal", token: "t", sessionID: "s", expiresAtUnix: 1),
            daemon: .init(url: "ws://x/rpc", token: "t", sessionID: "s", expiresAtUnix: 1)
        )
        #expect(throws: CmxCloudAttachError.invalidDaemonURL("ws://x/rpc")) {
            _ = try CmxCloudAttach().ticket(from: endpoint)
        }
    }

    @Test func ticketThrowsOnEmptyDaemonURL() {
        let endpoint = CmxCloudAttachEndpoint(
            terminal: .init(url: "wss://x/terminal", token: "t", sessionID: "s", expiresAtUnix: 1),
            daemon: .init(url: "   ", token: "t", sessionID: "s", expiresAtUnix: 1)
        )
        #expect(throws: CmxCloudAttachError.invalidDaemonURL("   ")) {
            _ = try CmxCloudAttach().ticket(from: endpoint)
        }
    }

    @Test func ticketThrowsOnEmptyDaemonToken() {
        let endpoint = CmxCloudAttachEndpoint(
            terminal: .init(url: "wss://x/terminal", token: "t", sessionID: "s", expiresAtUnix: 1),
            daemon: .init(url: "wss://x/rpc", token: "   ", sessionID: "s", expiresAtUnix: 1)
        )
        #expect(throws: CmxCloudAttachError.missingDaemonToken) {
            _ = try CmxCloudAttach().ticket(from: endpoint)
        }
    }
}
