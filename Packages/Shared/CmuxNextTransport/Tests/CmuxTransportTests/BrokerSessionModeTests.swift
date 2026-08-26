import CryptoKit
import Foundation
import Testing

@testable import CmuxNextTransport

/// Offline proof of the session-token broker mode (off-WiFi relay
/// credentials for a home-screen launch): a scripted transport stands in
/// for the staging broker, so the suite verifies auth headers, flow order,
/// transcript signatures, and credential shape with no network.
@Suite("broker session mode")
struct BrokerSessionModeTests {
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
            appIdentity: "dev.cmux.next.test", deviceID: "device-1")
    }

    private static func sessionConfig() -> BrokerCredentialClient.SessionConfig {
        BrokerCredentialClient.SessionConfig(
            baseUrl: "https://broker.example", deviceId: "device-1",
            appInstanceId: "device-1", tag: "next-transport-ios", platform: "ios")
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
                #"{"relayCredentials":[{"relayUrl":"https://r1.relay/","token":"tok-r1","expiresAt":1234},{"relayUrl":"https://r2.relay/","token":"tok-r2"}]}"#
            )
        default:
            return (404, "unexpected \(request.url!.absoluteString)")
        }
    }

    @Test("Session mint skips Stack sign-in and carries the session pair")
    func sessionMintUsesSessionHeaders() async throws {
        let script = ScriptedBroker(respond: Self.standardScript)
        let client = BrokerCredentialClient(
            sessionConfig: Self.sessionConfig(),
            tokens: {
                BrokerCredentialClient.SessionTokens(
                    accessToken: "access-1", refreshToken: "refresh-1")
            },
            identity: Self.identity(),
            transport: script.transport)

        let credentials = try await client.mint(preferredUrl: "https://r2.relay/")

        // No password sign-in leg: the first request is the broker challenge.
        let paths = script.requests.map(\.url!.path)
        #expect(paths == [
            "/api/devices/iroh/challenge",
            "/api/devices/iroh/register",
            "/api/relay/token",
        ])
        for request in script.requests {
            #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer access-1")
            #expect(request.value(forHTTPHeaderField: "x-stack-refresh-token") == "refresh-1")
        }
        // preferredUrl (the ticket's rendezvous relay) is served first.
        #expect(credentials.map(\.relayUrl) == ["https://r2.relay/", "https://r1.relay/"])
        #expect(credentials.first?.token == "tok-r2")
        #expect(credentials.last?.expiresAt == 1234)
    }

    @Test("Signed out fails closed before any network call")
    func signedOutFailsClosed() async throws {
        let script = ScriptedBroker { _ in (500, "must not be called") }
        let client = BrokerCredentialClient(
            sessionConfig: Self.sessionConfig(),
            tokens: { nil },
            identity: Self.identity(),
            transport: script.transport)

        await #expect(throws: BrokerCredentialClient.BrokerError.self) {
            _ = try await client.mint(preferredUrl: nil)
        }
        #expect(script.requests.isEmpty)
    }

    @Test("Register transcript is signed by the minting identity's own key")
    func registerSignatureBindsIdentity() async throws {
        let identity = Self.identity()
        let script = ScriptedBroker(respond: Self.standardScript)
        let client = BrokerCredentialClient(
            sessionConfig: Self.sessionConfig(),
            tokens: {
                BrokerCredentialClient.SessionTokens(
                    accessToken: "access-1", refreshToken: "refresh-1")
            },
            identity: identity,
            transport: script.transport)
        _ = try await client.mint(preferredUrl: nil)

        let register = try #require(
            script.requests.first { $0.url!.path == "/api/devices/iroh/register" })
        let registerBody = try #require(register.httpBody)
        let body = try #require(
            (try JSONDecoder().decode(JSONValue.self, from: registerBody)).objectValue)
        let payloadB64 = try #require(body["payload"]?.stringValue)
        let signatureB64 = try #require(body["signature"]?.stringValue)
        let payloadBytes = try #require(Self.base64urlDecode(payloadB64))
        let payloadSha = SHA256.hash(data: payloadBytes)
            .map { String(format: "%02x", $0) }.joined()
        let transcript = Data(
            "cmux/iroh/device-registration/v1\nc-1\nn-1\n\(payloadSha)".utf8)
        let signature = try #require(Self.base64urlDecode(signatureB64))
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: identity.publicKeyData)
        #expect(publicKey.isValidSignature(signature, for: transcript))
        // The registered endpointId is this identity's key, hex-encoded.
        let payload = try #require(
            (try JSONDecoder().decode(JSONValue.self, from: payloadBytes)).objectValue)
        let expectedEndpointId = identity.publicKeyData
            .map { String(format: "%02x", $0) }.joined()
        #expect(payload["endpointId"]?.stringValue == expectedEndpointId)
    }

    @Test("endpoint_already_bound register is success; tokens still issue")
    func alreadyBoundRegisterStillMints() async throws {
        let script = ScriptedBroker { request in
            switch request.url!.path {
            case "/api/devices/iroh/challenge":
                return (200, #"{"challenge_id":"c-1","nonce":"n-1"}"#)
            case "/api/devices/iroh/register":
                return (409, #"{"error":"endpoint_already_bound"}"#)
            case "/api/relay/token":
                return (
                    200,
                    #"{"relayCredentials":[{"relayUrl":"https://r1.relay/","token":"tok-r1"}]}"#
                )
            default:
                return (404, "unexpected")
            }
        }
        let client = BrokerCredentialClient(
            sessionConfig: Self.sessionConfig(),
            tokens: {
                BrokerCredentialClient.SessionTokens(
                    accessToken: "access-1", refreshToken: "refresh-1")
            },
            identity: Self.identity(),
            transport: script.transport)

        let credentials = try await client.mint(preferredUrl: nil)
        #expect(credentials.map(\.relayUrl) == ["https://r1.relay/"])
    }

    @Test("Each mint re-reads the CURRENT session pair (rotation-safe)")
    func mintRereadsRotatedTokens() async throws {
        let script = ScriptedBroker(respond: Self.standardScript)
        let counter = Counter()
        let client = BrokerCredentialClient(
            sessionConfig: Self.sessionConfig(),
            tokens: {
                let n = await counter.next()
                return BrokerCredentialClient.SessionTokens(
                    accessToken: "access-\(n)", refreshToken: "refresh-\(n)")
            },
            identity: Self.identity(),
            transport: script.transport)

        _ = try await client.mint(preferredUrl: nil)
        _ = try await client.mint(preferredUrl: nil)

        let bearers = Set(script.requests.compactMap {
            $0.value(forHTTPHeaderField: "authorization")
        })
        #expect(bearers == ["Bearer access-1", "Bearer access-2"])
    }

    @Test("Password mode still signs in to Stack first")
    func passwordModeSignsInFirst() async throws {
        let script = ScriptedBroker { request in
            switch request.url!.path {
            case "/api/v1/auth/password/sign-in":
                return (200, #"{"access_token":"stack-a","refresh_token":"stack-r"}"#)
            case "/api/devices/iroh/challenge":
                return (200, #"{"challenge_id":"c-1","nonce":"n-1"}"#)
            case "/api/devices/iroh/register":
                return (200, "{}")
            case "/api/relay/token":
                return (
                    200,
                    #"{"relayCredentials":[{"relayUrl":"https://r1.relay/","token":"tok-r1"}]}"#
                )
            default:
                return (404, "unexpected")
            }
        }
        let client = BrokerCredentialClient(
            config: BrokerCredentialClient.Config(
                baseUrl: "https://broker.example",
                stackBase: "https://stack.example",
                stackProjectId: "proj", stackPck: "pck",
                email: "dev@example.com", password: "pw",
                deviceId: "device-1", appInstanceId: "device-1",
                tag: "next-transport-ios", platform: "ios"),
            identity: Self.identity(),
            transport: script.transport)

        _ = try await client.mint(preferredUrl: nil)

        let first = try #require(script.requests.first)
        #expect(first.url!.host == "stack.example")
        #expect(first.url!.path == "/api/v1/auth/password/sign-in")
        let challenge = try #require(
            script.requests.first { $0.url!.path == "/api/devices/iroh/challenge" })
        #expect(challenge.value(forHTTPHeaderField: "authorization") == "Bearer stack-a")
        #expect(challenge.value(forHTTPHeaderField: "x-stack-refresh-token") == "stack-r")
    }

    private actor Counter {
        private var value = 0
        func next() -> Int {
            value += 1
            return value
        }
    }

    private static func base64urlDecode(_ value: String) -> Data? {
        var b64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64)
    }
}
