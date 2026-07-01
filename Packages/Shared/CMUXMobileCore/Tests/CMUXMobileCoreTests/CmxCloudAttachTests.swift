import Foundation
import Testing
@testable import CMUXMobileCore

/// Coverage for decoding the backend `POST /api/vm/{id}/attach-endpoint`
/// response into a ``CmxCloudAttachEndpoint`` — the cloud-route data contract
/// for issue #6700.
@Suite struct CmxCloudAttachTests {
    /// A header-less Freestyle-style WebSocket response (the default provider;
    /// it authorizes by token alone) with both the terminal PTY lease and the
    /// cmuxd-remote daemon lease. Mirrors `WebSocketPtyEndpoint` in
    /// `web/services/vms/drivers/types.ts`.
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
    /// handshake header the brokered upgrade requires (`drivers/e2b.ts`).
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

        // The daemon lease carries everything the cmuxd-remote handshake needs:
        // url, token, and session id.
        let daemon = try #require(endpoint.daemon)
        #expect(daemon.url == "wss://vm-123.vm.freestyle.sh/rpc")
        #expect(daemon.token == "cmux-freestyle-rpc-bbbb")
        #expect(daemon.sessionID == "sess-rpc-1")
        #expect(daemon.expiresAtUnix == 1_900_000_000)
        #expect(daemon.headers.isEmpty)
    }

    @Test func decodePreservesHandshakeHeaders() throws {
        // Decoding is faithful: an E2B endpoint keeps the per-lease headers the
        // brokered WebSocket upgrade requires, on both leases.
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

    @Test func decodeDefaultsTransportWhenAbsent() throws {
        let json = """
        {
          "url": "wss://vm-9.vm.freestyle.sh/terminal",
          "token": "t",
          "sessionId": "s",
          "expiresAtUnix": 1899999000
        }
        """
        let endpoint = try CmxCloudAttach().decode(data(json))
        #expect(endpoint.transport == "websocket")
        #expect(endpoint.terminal.headers.isEmpty)
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

    // MARK: - Codable round-trip

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

    // MARK: - Lease expiry

    @Test func leaseExpiresAtConvertsUnixSeconds() throws {
        let endpoint = try CmxCloudAttach().decode(
            data(freestyleResponseJSON(daemonExpiresAtUnix: 1_900_000_000))
        )
        #expect(endpoint.daemon?.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
    }

    @Test func leaseExpiresAtIsNilForNonPositiveValue() throws {
        // A missing/zero lease expiry must not pin the lease to the 1970 epoch
        // (which would read as instantly expired); it is treated as absent.
        let endpoint = try CmxCloudAttach().decode(
            data(freestyleResponseJSON(daemonExpiresAtUnix: 0))
        )
        #expect(endpoint.daemon?.expiresAtUnix == 0)
        #expect(endpoint.daemon?.expiresAt == nil)
    }
}
