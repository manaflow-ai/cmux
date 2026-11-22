import Foundation
import Synchronization
import Testing
@testable import CmuxNextCodeRouter

/// A fake CodeRouter control plane behind `URLProtocol`: records every
/// request and answers from a route table.
final class FakeCodeRouter: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: [String: String]
    }

    static let state = Mutex<(routes: [String: (Int, String)], log: [Recorded])>(([:], []))

    static func reset(_ routes: [String: (Int, String)]) { state.withLock { $0 = (routes, []) } }
    static var log: [Recorded] { state.withLock { $0.log } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeCodeRouter.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET", path = request.url?.path ?? ""
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close()
            bodyData = data
        }
        let object = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let body = object.mapValues { "\($0)" }
        let headers = (request.allHTTPHeaderFields ?? [:])
        let reply = Self.state.withLock { state -> (Int, String) in
            state.log.append(Recorded(method: method, path: path, headers: headers, body: body))
            return state.routes["\(method) \(path)"] ?? (404, #"{"error":"not_found"}"#)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct CodeRouterClientTests {
    let client = CodeRouterClient(baseURL: URL(string: "https://cmux.test/")!,
                                  tokens: { ("fixture-access", "fixture-refresh") }, teamID: { "team-1" },
                                  labeler: { fixtureLabeler }, session: FakeCodeRouter.session())

    @Test func listsBothFamiliesWithNativeAuthHeaders() async throws {
        FakeCodeRouter.reset([
            "GET /api/coderouter/accounts": (200, #"{"teamId":"team-1","accounts":[{"id":"a1","provider":"codex","label":"dev@example.com","providerAccountId":"acct-fixture","providerUserId":"user-fixture","state":"active","visibility":"private"},{"id":"a2","provider":"future-provider","label":"?"}]}"#),
            "GET /api/coderouter/claude-upstream": (200, #"{"teamId":"team-1","accounts":[{"id":"c1","kind":"anthropic_oauth","label":"","identifier":"sk-ant-oat01-…abcd","state":"active"}]}"#),
        ])
        let accounts = try await client.linkedAccounts()
        #expect(accounts.map(\.id) == ["a1", "c1"], "unknown providers are skipped")
        #expect(accounts[0].provider == .codex)
        #expect(accounts[1].provider == .claude)
        #expect(accounts[1].label == "sk-ant-oat01-…abcd", "a masked key is not personal data: kept")
        #expect(accounts[0].label == "d…@e…")
        #expect(accounts[0].account.handle == codexHandle())
        let request = try #require(FakeCodeRouter.log.first)
        #expect(request.headers["Authorization"] == "Bearer fixture-access")
        #expect(request.headers["X-Stack-Refresh-Token"] == "fixture-refresh")
        #expect(request.headers["X-Cmux-Team-Id"] == "team-1")
    }

    @Test func addRoutesEachCredentialToItsFamilyAsPrivate() async throws {
        FakeCodeRouter.reset([
            "POST /api/coderouter/accounts": (201, #"{"alreadyExists":false}"#),
            "POST /api/coderouter/claude-upstream": (201, #"{"teamId":"team-1"}"#),
        ])
        try await client.add(.apiKey(serverProvider: "openrouter-apikey", key: "sk-or-v1-fixture-0000000000", label: "work"))
        try await client.add(.claudeOAuthToken("sk-ant-oat01-fixture-000000000000", label: nil))
        let log = FakeCodeRouter.log
        #expect(log.map(\.path) == ["/api/coderouter/accounts", "/api/coderouter/claude-upstream"])
        #expect(log[0].body["provider"] == "openrouter-apikey")
        #expect(log[0].body["label"] == "work")
        #expect(log[0].body["visibility"] == "private")
        #expect(log[1].body["kind"] == "anthropic_oauth")
        #expect(log[1].body["visibility"] == "private")
    }

    @Test func removeIsIdempotentAndEncodesTheID() async throws {
        FakeCodeRouter.reset(["DELETE /api/coderouter/claude-upstream/c1": (200, #"{"removed":true}"#)])
        let account = LinkedAccount(id: "c1", family: .claude, provider: .claude, account: AccountLabel(handle: "acct_x", display: "x"),
                                    state: "active")
        #expect(try await client.remove(account))
        var gone = account
        gone.id = "missing"
        #expect(try await client.remove(gone) == false)
        await #expect(throws: CodeRouterError.self) {
            var bad = account
            bad.id = ".."
            try await client.remove(bad)
        }
    }

    @Test func failuresCarryServerMessageAndNeverTheRequestBody() async throws {
        FakeCodeRouter.reset(["POST /api/coderouter/accounts": (400, #"{"error":"invalid_credential","message":"Sign in to Codex again before adding this account."}"#)])
        do {
            try await client.add(.apiKey(serverProvider: "openai-apikey", key: "sk-fixture-secret-0000000000", label: nil))
            Issue.record("expected a failure")
        } catch let error as CodeRouterError {
            #expect(error == .http(status: 400, code: "invalid_credential", message: "Sign in to Codex again before adding this account."))
            #expect(!error.description.contains("sk-fixture-secret"))
        }
        FakeCodeRouter.reset(["GET /api/coderouter/accounts": (401, "{}")])
        await #expect(throws: CodeRouterError.notSignedIn) { _ = try await client.send("GET", "/api/coderouter/accounts") }
    }

    @Test func signedOutFailsBeforeAnyRequest() async throws {
        FakeCodeRouter.reset([:])
        struct NoSession: Error {}
        let signedOut = CodeRouterClient(baseURL: URL(string: "https://cmux.test")!, tokens: { throw NoSession() },
                                         teamID: { nil }, labeler: { fixtureLabeler }, session: FakeCodeRouter.session())
        await #expect(throws: CodeRouterError.notSignedIn) { _ = try await signedOut.linkedAccounts() }
        #expect(FakeCodeRouter.log.isEmpty)
    }

    @Test func credentialDescriptionsAreRedacted() {
        let values: [CodeRouterCredential] = [
            .apiKey(serverProvider: "openai-apikey", key: "sk-fixture-secret", label: nil),
            .claudeOAuthToken("sk-ant-oat01-fixture-secret", label: nil),
            .anthropicAPIKey("sk-ant-fixture-secret", label: nil),
            .bedrock(region: "us-east-1", accessKeyID: "AKIAFIXTURE", secretAccessKey: "fixture-secret", sessionToken: nil, label: nil),
        ]
        for value in values {
            #expect(!"\(value)".contains("secret"))
            #expect(!"\(value)".contains("FIXTURE"))
        }
    }
}
