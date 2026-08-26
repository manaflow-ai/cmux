import Foundation
import Testing

@testable import CmuxNextTransport

/// Offline proof of the environment-based broker construction and the
/// credential-flow hardening: scripted transports stand in for the staging
/// broker, so error redaction, malformed-URL handling, structured
/// bootstrap-vs-mint branching, and expiry surfacing are all verified with
/// no network.
@Suite("next-transport environment")
struct NextTransportEnvironmentTests {
    /// Records every request and answers from a per-path script.
    private final class ScriptedBroker: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        private let respond: @Sendable (URLRequest) -> (Int, String)

        init(respond: @escaping @Sendable (URLRequest) -> (Int, String)) {
            self.respond = respond
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        private func handle(_ request: URLRequest) -> (Data, URLResponse) {
            lock.lock()
            recorded.append(request)
            lock.unlock()
            let (status, body) = respond(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }

        var transport: BrokerCredentialClient.Transport {
            { request in self.handle(request) }
        }
    }

    private static func identity() -> PeerIdentity {
        PeerIdentity.generate(
            appIdentity: "dev.cmux.next.test", deviceID: "device-env-1")
    }

    private static func environment(
        broker: String = "https://broker.example"
    ) -> NextTransportEnvironment {
        NextTransportEnvironment(
            brokerBaseURL: URL(string: broker)!,
            stackAuthBaseURL: URL(string: "https://stack.example")!,
            stackProjectID: "proj-env",
            stackPublishableClientKey: "pck-env")
    }

    private static func sessionTokens() -> @Sendable () async throws
        -> BrokerCredentialClient.SessionTokens?
    {
        {
            BrokerCredentialClient.SessionTokens(
                accessToken: "access-env", refreshToken: "refresh-env")
        }
    }

    /// An unsigned JWT whose payload carries only `exp`, for the offline
    /// expiry-fallback paths (IrohSubstrate.tokenExpiry only base64-decodes
    /// the middle segment).
    private static func fakeJWT(exp: Int64) -> String {
        let payload = try! JSONEncoder().encode(JSONValue.object(["exp": .int(exp)]))
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(b64).sig"
    }

    /// The standard three-leg script: challenge, register, relay token.
    private static func standardScript(
        _ request: URLRequest
    ) -> (Int, String) {
        switch request.url!.path {
        case "/api/devices/iroh/challenge":
            return (200, #"{"challenge_id":"c-1","nonce":"n-1"}"#)
        case "/api/devices/iroh/register":
            return (200, "{}")
        case "/api/relay/token":
            return (
                200,
                #"{"relayCredentials":[{"relayUrl":"https://r1.relay/","token":"tok-r1","expiresAt":1234}]}"#
            )
        default:
            return (404, "unexpected \(request.url!.path)")
        }
    }

    @Test("staging matches the constants the call sites previously hardcoded")
    func stagingConstants() {
        let env = NextTransportEnvironment.staging
        #expect(env.brokerBaseURL.absoluteString == "https://cmux-staging.vercel.app")
        #expect(env.stackAuthBaseURL.absoluteString == "https://api.stack-auth.com")
        #expect(env.stackProjectID == "454ecd03-1db2-4050-845e-4ce5b0cd9895")
        #expect(env.stackPublishableClientKey
            == "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g")
        #expect(env.credentialMode == .tokenMinting)
    }

    @Test("Environment session auth fails closed on a nil token pair")
    func sessionAuthFailsClosed() async throws {
        let script = ScriptedBroker { _ in (500, "must not be called") }
        let client = BrokerCredentialClient(
            environment: Self.environment(), identity: Self.identity(),
            auth: .session(tokens: { nil }),
            transport: script.transport)

        do {
            _ = try await client.mint(preferredUrl: nil)
            Issue.record("mint must throw when signed out")
        } catch let error as BrokerCredentialClient.BrokerError {
            guard case .notSignedIn = error else {
                Issue.record("expected notSignedIn, got \(error)")
                return
            }
        }
        #expect(script.requests.isEmpty)
    }

    @Test("Environment password auth signs in at the environment's Stack deployment")
    func passwordAuthUsesEnvironmentStack() async throws {
        let script = ScriptedBroker { request in
            if request.url!.path == "/api/v1/auth/password/sign-in" {
                return (200, #"{"access_token":"stack-a","refresh_token":"stack-r"}"#)
            }
            return Self.standardScript(request)
        }
        let client = BrokerCredentialClient(
            environment: Self.environment(), identity: Self.identity(),
            auth: .password(email: "dev@example.com", password: "pw"),
            tag: "next-transport-test",
            transport: script.transport)

        let credentials = try await client.mint(preferredUrl: nil)
        #expect(!credentials.isEmpty)

        let signIn = try #require(script.requests.first)
        #expect(signIn.url!.host == "stack.example")
        #expect(signIn.value(forHTTPHeaderField: "x-stack-project-id") == "proj-env")
        #expect(signIn.value(forHTTPHeaderField: "x-stack-publishable-client-key") == "pck-env")
        let challenge = try #require(
            script.requests.first { $0.url!.path == "/api/devices/iroh/challenge" })
        #expect(challenge.url!.host == "broker.example")
        #expect(challenge.value(forHTTPHeaderField: "authorization") == "Bearer stack-a")
    }

    @Test("HTTP errors carry status, path, and code — never the response body")
    func httpErrorRedactsBody() async throws {
        let leakedToken = "secret-access-token-XYZZY"
        let script = ScriptedBroker { _ in
            (
                401,
                #"{"error":"unauthorized","access_token":"\#(leakedToken)","detail":"Bearer \#(leakedToken)"}"#
            )
        }
        let client = BrokerCredentialClient(
            environment: Self.environment(), identity: Self.identity(),
            auth: .session(tokens: Self.sessionTokens()),
            transport: script.transport)

        do {
            _ = try await client.mint(preferredUrl: nil)
            Issue.record("mint must throw on HTTP 401")
        } catch let error as BrokerCredentialClient.BrokerError {
            let rendered = "\(error)"
            #expect(!rendered.contains(leakedToken))
            #expect(rendered.contains("401"))
            #expect(rendered.contains("/api/devices/iroh/challenge"))
            #expect(rendered.contains("unauthorized"))
            guard case .http(_, let status, let path, let code) = error else {
                Issue.record("expected .http, got \(error)")
                return
            }
            #expect(status == 401)
            #expect(path == "/api/devices/iroh/challenge")
            #expect(code == "unauthorized")
        }
    }

    @Test("A malformed request URL throws a typed error before any network call")
    func malformedURLThrowsTypedError() async throws {
        let script = ScriptedBroker { _ in (500, "must not be called") }
        let client = BrokerCredentialClient(
            sessionConfig: BrokerCredentialClient.SessionConfig(
                baseUrl: "not a url", deviceId: "device-env-1",
                appInstanceId: "device-env-1", tag: "t", platform: "mac"),
            tokens: Self.sessionTokens(),
            identity: Self.identity(),
            transport: script.transport)

        do {
            _ = try await client.mint(preferredUrl: nil)
            Issue.record("mint must throw on a malformed base URL")
        } catch let error as BrokerCredentialClient.BrokerError {
            guard case .malformedURL(let step, _) = error else {
                Issue.record("expected malformedURL, got \(error)")
                return
            }
            #expect(step == "broker challenge")
        }
        #expect(script.requests.isEmpty)
    }

    @Test("Structured endpoint_already_bound register still mints via /api/relay/token")
    func structuredAlreadyBoundStillMints() async throws {
        let script = ScriptedBroker { request in
            if request.url!.path == "/api/devices/iroh/register" {
                return (409, #"{"error":"endpoint_already_bound"}"#)
            }
            return Self.standardScript(request)
        }
        let client = BrokerCredentialClient(
            environment: Self.environment(), identity: Self.identity(),
            auth: .session(tokens: Self.sessionTokens()),
            transport: script.transport)

        let credentials = try await client.mint(preferredUrl: nil)
        #expect(credentials.map(\.relayUrl) == ["https://r1.relay/"])
        #expect(script.requests.map(\.url!.path).contains("/api/relay/token"))
    }

    @Test("Non-JSON already-bound body still succeeds via the substring fallback")
    func nonJSONAlreadyBoundFallback() async throws {
        let script = ScriptedBroker { request in
            if request.url!.path == "/api/devices/iroh/register" {
                return (409, "conflict: endpoint_already_bound (legacy body)")
            }
            return Self.standardScript(request)
        }
        let client = BrokerCredentialClient(
            environment: Self.environment(), identity: Self.identity(),
            auth: .session(tokens: Self.sessionTokens()),
            transport: script.transport)

        let credentials = try await client.mint(preferredUrl: nil)
        #expect(credentials.map(\.relayUrl) == ["https://r1.relay/"])
    }

    @Test("A register-bootstrapped grant skips the /api/relay/token mint")
    func bootstrapGrantSkipsMint() async throws {
        let expiry: Int64 = 1_900_000_000
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(expiry)))
        let register = """
            {"relay":{"status":"issued","token":"tok-boot","expires_at":"\(expiresAt)",\
            "relay_fleet":["https://r1.relay/","https://r2.relay/"]}}
            """
        let script = ScriptedBroker { request in
            if request.url!.path == "/api/devices/iroh/register" {
                return (200, register)
            }
            return Self.standardScript(request)
        }
        let client = BrokerCredentialClient(
            environment: Self.environment(), identity: Self.identity(),
            auth: .session(tokens: Self.sessionTokens()),
            transport: script.transport)

        let credentials = try await client.mint(preferredUrl: "https://r2.relay/")
        #expect(!script.requests.map(\.url!.path).contains("/api/relay/token"))
        #expect(credentials.map(\.relayUrl) == ["https://r2.relay/", "https://r1.relay/"])
        #expect(credentials.map(\.token) == ["tok-boot", "tok-boot"])
        #expect(credentials.map(\.expiresAt) == [expiry, expiry])
    }

    @Test("An unavailable register grant explicitly falls back to the mint")
    func bootstrapUnavailableFallsBackToMint() async throws {
        let script = ScriptedBroker { request in
            if request.url!.path == "/api/devices/iroh/register" {
                return (200, #"{"relay":{"status":"unavailable"}}"#)
            }
            return Self.standardScript(request)
        }
        let client = BrokerCredentialClient(
            environment: Self.environment(), identity: Self.identity(),
            auth: .session(tokens: Self.sessionTokens()),
            transport: script.transport)

        let credentials = try await client.mint(preferredUrl: nil)
        #expect(script.requests.map(\.url!.path).contains("/api/relay/token"))
        #expect(credentials.map(\.relayUrl) == ["https://r1.relay/"])
        #expect(credentials.first?.expiresAt == 1234)
    }

    @Test("Missing server expiry falls back to the token's own JWT exp claim")
    func expiryFallsBackToJwtExp() async throws {
        let jwt = Self.fakeJWT(exp: 1_234_567)
        let script = ScriptedBroker { request in
            switch request.url!.path {
            case "/api/devices/iroh/challenge":
                return (200, #"{"challenge_id":"c-1","nonce":"n-1"}"#)
            case "/api/devices/iroh/register":
                return (200, "{}")
            case "/api/relay/token":
                return (
                    200,
                    #"{"relayCredentials":[{"relayUrl":"https://r1.relay/","token":"\#(jwt)"}]}"#
                )
            default:
                return (404, "unexpected")
            }
        }
        let client = BrokerCredentialClient(
            environment: Self.environment(), identity: Self.identity(),
            auth: .session(tokens: Self.sessionTokens()),
            transport: script.transport)

        let credentials = try await client.mint(preferredUrl: nil)
        #expect(credentials.first?.expiresAt == 1_234_567)
    }
}
