import Foundation
import Testing
@testable import CMUXMobileCore

/// Round-trip coverage for ``CmxAttachTicket`` wire compatibility.
///
/// The mac side of PR 5079 already speaks the current mixed-key shape
/// (camelCase fields plus `auth_token`). These tests pin the encode bytes to
/// that shape and prove the tolerant decoder accepts both the current
/// `auth_token` key and a normalized `authToken` key.

private func makeRoutes() throws -> [CmxAttachRoute] {
    [
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.2", port: 49831),
            priority: 1
        ),
    ]
}

private func futureExpiry() -> Date {
    Date(timeIntervalSince1970: 4_000_000_000)
}

private func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

private func canonicalDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

@Test func attachTicketEncodesAuthTokenUnderSnakeCaseKey() throws {
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-1",
        terminalID: "terminal-9",
        macDeviceID: "mac-1",
        macDisplayName: "Studio",
        routes: makeRoutes(),
        expiresAt: futureExpiry(),
        authToken: "ticket-secret"
    )

    let data = try canonicalEncoder().encode(ticket)
    let json = try #require(String(data: data, encoding: .utf8))

    // The auth token field stays on the historical snake_case key so the mac
    // side keeps decoding it; the other fields stay camelCase.
    #expect(json.contains("\"auth_token\":\"ticket-secret\""))
    #expect(!json.contains("\"authToken\""))
    #expect(json.contains("\"workspaceID\":\"workspace-1\""))
    #expect(json.contains("\"terminalID\":\"terminal-9\""))
    #expect(json.contains("\"macDeviceID\":\"mac-1\""))
    #expect(json.contains("\"macDisplayName\":\"Studio\""))
    #expect(json.contains("\"expiresAt\""))
}

@Test func attachTicketRoundTripsThroughCanonicalEncoder() throws {
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-1",
        terminalID: nil,
        macDeviceID: "mac-1",
        macDisplayName: nil,
        routes: makeRoutes(),
        expiresAt: futureExpiry(),
        authToken: "ticket-secret"
    )

    let data = try canonicalEncoder().encode(ticket)
    let decoded = try canonicalDecoder().decode(CmxAttachTicket.self, from: data)
    #expect(decoded == ticket)
}

@Test func attachTicketDecodesCurrentSnakeCaseAuthTokenShape() throws {
    // The exact mixed shape the mac side emits today.
    let json = """
    {
      "version": 1,
      "workspaceID": "workspace-1",
      "terminalID": "terminal-3",
      "macDeviceID": "mac-1",
      "macDisplayName": "Studio",
      "routes": [
        { "id": "tailscale", "kind": "tailscale",
          "endpoint": { "type": "host_port", "host": "100.64.1.2", "port": 49831 },
          "priority": 1 }
      ],
      "expiresAt": "2096-10-02T07:06:40Z",
      "auth_token": "ticket-secret"
    }
    """

    let decoded = try canonicalDecoder().decode(
        CmxAttachTicket.self,
        from: try #require(json.data(using: .utf8))
    )
    #expect(decoded.authToken == "ticket-secret")
    #expect(decoded.workspaceID == "workspace-1")
    #expect(decoded.terminalID == "terminal-3")
}

@Test func attachTicketDecodesNormalizedCamelCaseAuthTokenShape() throws {
    // A future normalized producer that moves the token onto a camelCase key
    // must still decode.
    let json = """
    {
      "version": 1,
      "workspaceID": "workspace-1",
      "terminalID": null,
      "macDeviceID": "mac-1",
      "macDisplayName": null,
      "routes": [
        { "id": "tailscale", "kind": "tailscale",
          "endpoint": { "type": "host_port", "host": "100.64.1.2", "port": 49831 },
          "priority": 1 }
      ],
      "expiresAt": "2096-10-02T07:06:40Z",
      "authToken": "ticket-secret"
    }
    """

    let decoded = try canonicalDecoder().decode(
        CmxAttachTicket.self,
        from: try #require(json.data(using: .utf8))
    )
    #expect(decoded.authToken == "ticket-secret")
}

@Test func attachTicketPrefersSnakeCaseAuthTokenWhenBothKeysPresent() throws {
    let json = """
    {
      "version": 1,
      "workspaceID": "workspace-1",
      "terminalID": null,
      "macDeviceID": "mac-1",
      "macDisplayName": null,
      "routes": [
        { "id": "tailscale", "kind": "tailscale",
          "endpoint": { "type": "host_port", "host": "100.64.1.2", "port": 49831 },
          "priority": 1 }
      ],
      "expiresAt": "2096-10-02T07:06:40Z",
      "auth_token": "canonical-secret",
      "authToken": "camel-secret"
    }
    """

    let decoded = try canonicalDecoder().decode(
        CmxAttachTicket.self,
        from: try #require(json.data(using: .utf8))
    )
    #expect(decoded.authToken == "canonical-secret")
}

@Test func attachTicketDecodesMissingAuthTokenAsNil() throws {
    let json = """
    {
      "version": 1,
      "workspaceID": "workspace-1",
      "terminalID": null,
      "macDeviceID": "mac-1",
      "macDisplayName": null,
      "routes": [
        { "id": "tailscale", "kind": "tailscale",
          "endpoint": { "type": "host_port", "host": "100.64.1.2", "port": 49831 },
          "priority": 1 }
      ],
      "expiresAt": "2096-10-02T07:06:40Z"
    }
    """

    let decoded = try canonicalDecoder().decode(
        CmxAttachTicket.self,
        from: try #require(json.data(using: .utf8))
    )
    #expect(decoded.authToken == nil)
}
