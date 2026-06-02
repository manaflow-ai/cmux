import Testing
@testable import CmuxGitHosting
import Foundation

/// Decoding edge cases for the `cmux.json` provider DSL: optional keys and the
/// difference between an absent key (use a default) and an explicit `null`.
@Suite struct GitHostingDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: #require(json.data(using: .utf8)))
    }

    @Test func tokenSourceAllowsOmittingEnvironment() throws {
        let source = try decode(GitHostingTokenSource.self, #"{"command":["gh","auth","token"]}"#)
        #expect(source.environment == [])
        #expect(source.command == ["gh", "auth", "token"])
    }

    @Test func authSchemeDefaultsToBearerWhenAbsentButRespectsExplicitNull() throws {
        let absent = try decode(GitHostingAuthSpec.self, #"{"token":{"environment":["X"]}}"#)
        #expect(absent.scheme == "Bearer")

        let explicitNull = try decode(GitHostingAuthSpec.self, #"{"scheme":null,"token":{"environment":["X"]}}"#)
        #expect(explicitNull.scheme == nil)
    }

    @Test func explicitNullSchemeSendsRawTokenWithoutPrefix() throws {
        let spec = try decode(GitHostingProviderSpec.self, """
        {
          "apiBaseURL": "https://{host}/api/v1/",
          "pullRequestsPath": "repos/{path}/pulls",
          "auth": { "scheme": null, "token": { "environment": ["X"] } },
          "response": { "number": "id", "url": "url", "state": "state",
            "headRef": "head", "stateMap": { "OPEN": "OPEN" } }
        }
        """)
        let plan = GitHostingRequestPlan(spec: spec, apiHost: "git.internal", token: "rawtok")
        let ref = try #require(GitRemoteReference.parse(remoteURL: "git@git.internal:team/app.git"))
        let request = try #require(plan.repositoryRequest(for: ref, page: 1))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "rawtok")
    }

    @Test func nullPaginationParamsOmitPagingQueryItems() throws {
        let spec = try decode(GitHostingProviderSpec.self, """
        {
          "apiBaseURL": "https://{host}/api/v1/",
          "pullRequestsPath": "repos/{path}/pulls",
          "pageParam": null,
          "perPageParam": null,
          "auth": { "token": { "environment": ["X"] } },
          "response": { "number": "id", "url": "url", "state": "state",
            "headRef": "head", "stateMap": { "OPEN": "OPEN" } }
        }
        """)
        #expect(spec.pageParam == nil)
        #expect(spec.perPageParam == nil)
        let plan = GitHostingRequestPlan(spec: spec, apiHost: "git.internal", token: "t")
        let ref = try #require(GitRemoteReference.parse(remoteURL: "git@git.internal:team/app.git"))
        let request = try #require(plan.repositoryRequest(for: ref, page: 1))
        let pairs = queryPairs(of: request)
        #expect(!pairs.contains { $0.hasPrefix("page=") })
        #expect(!pairs.contains { $0.hasPrefix("per_page=") })
    }

    @Test func defaultAndBracketedIPv6PortsNormalizeIntoIdentity() throws {
        // Default HTTPS port is dropped so the same repo is one cache identity.
        let defaultPort = try #require(GitRemoteReference.parse(remoteURL: "https://gitlab.example.com:443/team/app.git"))
        #expect(defaultPort.httpsPort == nil)
        #expect(defaultPort.identity == "gitlab.example.com/team/app")

        // A bracketed IPv6 SCP host is parsed instead of being mangled.
        let ipv6 = try #require(GitRemoteReference.parse(remoteURL: "git@[2001:db8::1]:team/app.git"))
        #expect(ipv6.host == "2001:db8::1")
        #expect(ipv6.path == "team/app")
    }
}
