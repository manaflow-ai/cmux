import Foundation
import Testing
@testable import CmuxSubrouter

/// Decodes captured daemon payload shapes: snake_case account fields with
/// PascalCase window/credit keys, omitempty booleans, RFC3339Nano dates.
@Suite struct PayloadDecodingTests {
    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = SubrouterHTTPClient.parseTimestamp(raw) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: raw)
                )
            }
            return date
        }
        return decoder
    }

    @Test func decodesUsageStatusRow() throws {
        let json = """
        [
          {
            "id": "dev@example.com",
            "provider": "codex",
            "auth_mode": "oauth",
            "email": "dev@example.com",
            "source": "/Users/dev/.codex-accounts/dev.json",
            "auth_checked": true,
            "auth_valid": true,
            "active": true,
            "plan_type": "pro",
            "windows": [
              {"Name": "primary", "UsedPercent": 42.5, "LimitWindowSeconds": 18000, "ResetAfterSeconds": 1234, "Feature": ""},
              {"Name": "secondary", "UsedPercent": 91.0, "LimitWindowSeconds": 604800, "ResetAfterSeconds": 250000, "Feature": ""}
            ],
            "credits": {"HasCredits": true, "Unlimited": false, "Balance": "$12.50"}
          },
          {
            "id": "work",
            "provider": "claude",
            "auth_mode": "oauth",
            "source": "/Users/dev/.subrouter/codex/claude/work",
            "auth_checked": true,
            "auth_valid": true,
            "plan_type": "claude",
            "windows": [
              {"Name": "5h", "UsedPercent": 100, "LimitWindowSeconds": 0, "ResetAfterSeconds": 900, "Feature": ""}
            ]
          }
        ]
        """
        let rows = try makeDecoder().decode([SubrouterAccountUsageStatus].self, from: Data(json.utf8))
        #expect(rows.count == 2)

        let codex = try #require(rows.first)
        #expect(codex.id == "dev@example.com")
        #expect(codex.provider == .codex)
        #expect(codex.authMode == .oauth)
        #expect(codex.isActive)
        #expect(codex.planType == "pro")
        #expect(codex.windows.count == 2)
        #expect(codex.windows[0].name == "primary")
        #expect(codex.windows[0].usedPercent == 42.5)
        #expect(codex.windows[0].limitWindowSeconds == 18000)
        #expect(codex.windows[1].isNearlyExhausted)
        #expect(codex.credits == SubrouterCredits(hasCredits: true, unlimited: false, balance: "$12.50"))

        let claude = rows[1]
        // `active` and `email` are omitempty on the wire: absent means false/nil.
        #expect(!claude.isActive)
        #expect(claude.email == nil)
        #expect(claude.credits == nil)
        #expect(claude.quotaAssessment == .tempCooked(claude.windows[0]))
        #expect(claude.displayName == "work")
    }

    @Test func decodesAccountsRow() throws {
        let json = """
        [{"id": "dev@example.com", "provider": "codex", "auth_mode": "apikey", "source": ""}]
        """
        let accounts = try makeDecoder().decode([SubrouterAccount].self, from: Data(json.utf8))
        #expect(accounts.count == 1)
        #expect(accounts[0].authMode == .apiKey)
        #expect(accounts[0].email == nil)
    }

    @Test func rowsMissingAccountIdentityFailClosed() {
        // Identity is the SwiftUI row id and the `sr switch` target: a row
        // without it must fail the response closed, never synthesize an
        // empty id several malformed rows would share.
        let missingID = Data("""
        [{"provider": "codex", "auth_mode": "oauth", "source": ""}]
        """.utf8)
        let emptyID = Data("""
        [{"id": "", "provider": "codex", "auth_mode": "oauth", "source": ""}]
        """.utf8)
        let missingProvider = Data("""
        [{"id": "dev@example.com", "auth_mode": "oauth", "source": ""}]
        """.utf8)
        for payload in [missingID, emptyID, missingProvider] {
            #expect(throws: DecodingError.self) {
                try makeDecoder().decode([SubrouterAccountUsageStatus].self, from: payload)
            }
            #expect(throws: DecodingError.self) {
                try makeDecoder().decode([SubrouterAccount].self, from: payload)
            }
        }
    }

    @Test func decodesUnknownProviderLosslessly() throws {
        let json = """
        [{"id": "x", "provider": "gemini", "auth_mode": "oauth", "source": ""}]
        """
        let accounts = try makeDecoder().decode([SubrouterAccount].self, from: Data(json.utf8))
        #expect(accounts[0].provider == SubrouterProvider(rawValue: "gemini"))
        #expect(!accounts[0].provider.supportsSwitching)
    }

    @Test func decodesSessionAssignmentsWithNanoTimestamps() throws {
        let json = """
        [
          {
            "agent_type": "codex",
            "session_id": "sess-1",
            "account_id": "dev@example.com",
            "user_email": "dev@example.com",
            "created_at": "2026-07-15T12:34:56.789012-07:00",
            "updated_at": "2026-07-15T12:40:00Z"
          }
        ]
        """
        let sessions = try makeDecoder().decode([SubrouterSessionAssignment].self, from: Data(json.utf8))
        let session = try #require(sessions.first)
        #expect(session.agentType == "codex")
        #expect(session.sessionID == "sess-1")
        #expect(session.accountID == "dev@example.com")
        #expect(session.id == "codex:sess-1")
        // Fractional-seconds and plain RFC 3339 forms both parse, offsets
        // normalized to UTC.
        #expect(abs(session.createdAt.timeIntervalSince1970 - 1_784_144_096.789012) < 0.001)
        #expect(session.updatedAt.timeIntervalSince1970 == 1_784_119_200)
    }

    @Test func decodesReloadResult() throws {
        let json = """
        {"ok": true, "accounts": 4, "usage_refreshed": 3}
        """
        let result = try makeDecoder().decode(SubrouterReloadResult.self, from: Data(json.utf8))
        #expect(result == SubrouterReloadResult(ok: true, accounts: 4, usageRefreshed: 3))
    }

    @Test func endpointParsing() {
        #expect(SubrouterEndpoint(configurationString: "")?.baseURL == nil)
        #expect(SubrouterEndpoint(configurationString: "   ") == nil)
        #expect(
            SubrouterEndpoint(configurationString: "127.0.0.1:31415")?.baseURL.absoluteString
                == "http://127.0.0.1:31415"
        )
        #expect(
            SubrouterEndpoint(configurationString: "http://localhost:9999")?.baseURL.absoluteString
                == "http://localhost:9999"
        )
        #expect(SubrouterEndpoint(configurationString: "ftp://bad") == nil)
        // Token-free contract: the endpoint string is echoed by status and
        // CLI JSON output, so embedded credentials are rejected outright.
        #expect(SubrouterEndpoint(configurationString: "http://user:secret@127.0.0.1:31415") == nil)
        #expect(SubrouterEndpoint(configurationString: "https://user@remote.example.com") == nil)
        let standard = SubrouterEndpoint.standard
        #expect(
            standard.url(forPath: "/_subrouter/health").absoluteString
                == "http://127.0.0.1:31415/_subrouter/health"
        )
    }
}

@Suite struct ServerSelectionTests {
    @Test func parsesDefaultServerFromRegistry() throws {
        let json = Data("""
        {"servers": [{"name": "cmux-mac-mini", "url": "http://cmux-mac-mini:31415"},
                     {"name": "team", "url": "http://subrouter-team:31415"}],
         "default": "cmux-mac-mini"}
        """.utf8)
        let selection = try #require(SubrouterServerSelection(serversJSON: json))
        let server = try #require(selection.defaultServer)
        #expect(server.name == "cmux-mac-mini")
        #expect(server.endpoint.baseURL.absoluteString == "http://cmux-mac-mini:31415")
        #expect(server.endpoint.adminToken == nil)
    }

    @Test func preservesAdminTokenForSecuredRemoteServer() throws {
        // Non-loopback /_subrouter/* endpoints 401 without the registry's
        // adminToken; dropping it here would break every remote request.
        let json = Data("""
        {"servers": [{"name": "team", "url": "http://subrouter-team:31415",
                      "adminToken": "secret-token"}],
         "default": "team"}
        """.utf8)
        let selection = try #require(SubrouterServerSelection(serversJSON: json))
        let server = try #require(selection.defaultServer)
        #expect(server.endpoint.adminToken == "secret-token")
        // The token never rides in the URL user-facing surfaces render.
        #expect(server.endpoint.baseURL.absoluteString == "http://subrouter-team:31415")

        let blank = Data("""
        {"servers": [{"name": "team", "url": "http://subrouter-team:31415", "adminToken": "  "}],
         "default": "team"}
        """.utf8)
        let blankSelection = try #require(SubrouterServerSelection(serversJSON: blank))
        #expect(blankSelection.defaultServer?.endpoint.adminToken == nil)
    }

    @Test func missingDefaultMeansLocalDaemon() throws {
        let json = Data(#"{"servers": [{"name": "team", "url": "http://subrouter-team:31415"}]}"#.utf8)
        let selection = try #require(SubrouterServerSelection(serversJSON: json))
        #expect(selection.defaultServer == nil)
    }

    @Test func undecodableRegistryReturnsNil() {
        #expect(SubrouterServerSelection(serversJSON: Data("not json".utf8)) == nil)
    }

    @Test func defaultNamingUnknownServerFailsClosed() {
        // A registry that still names a default the entry list cannot
        // resolve is inconsistent, not a local-daemon selection: parsing
        // fails so the runtime treats it as unreadable instead of falling
        // back to loopback.
        #expect(SubrouterServerSelection(serversJSON: Data(#"{"servers": [], "default": "gone"}"#.utf8)) == nil)
        #expect(SubrouterServerSelection(
            serversJSON: Data(#"{"servers": [{"name": "team", "url": "ftp://subrouter-team:31415"}], "default": "team"}"#.utf8)
        ) == nil)
    }
}
