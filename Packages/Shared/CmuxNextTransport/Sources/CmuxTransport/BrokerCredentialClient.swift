import CryptoKit
import Foundation

/// The phone mints its OWN relay credentials over HTTPS, exactly as the
/// production app will (contract 9.6/9.7): authenticate, prove key ownership
/// to the trust broker, fetch endpoint-bound fleet tokens. This removes every
/// external delivery dependency that failed in the field: ctl pushes need a
/// live session, devicectl relaunches need a reachable phone — but a device
/// that can reach the internet can always fetch its own pass.
///
/// Two authentication modes share one broker flow:
/// - password: dev harnesses mint a fresh Stack session from an email and
///   password pair (mirrors iroh-testbed/tools/get-relay-token.mjs).
/// - session: the app's ALREADY signed-in Stack session supplies the token
///   pair, exactly as the legacy transport's trust broker client
///   authenticates (`Authorization: Bearer` + `X-Stack-Refresh-Token`). No
///   raw credentials ever enter this client; the provider re-reads the
///   CURRENT pair per mint so token rotation never strands it.
public struct BrokerCredentialClient: Sendable {
    public struct Config: Sendable, Decodable {
        public var baseUrl: String
        public var stackBase: String
        public var stackProjectId: String
        public var stackPck: String
        public var email: String
        public var password: String
        public var deviceId: String
        public var appInstanceId: String
        public var tag: String
        public var platform: String

        public init(
            baseUrl: String, stackBase: String, stackProjectId: String,
            stackPck: String, email: String, password: String,
            deviceId: String, appInstanceId: String, tag: String, platform: String
        ) {
            self.baseUrl = baseUrl
            self.stackBase = stackBase
            self.stackProjectId = stackProjectId
            self.stackPck = stackPck
            self.email = email
            self.password = password
            self.deviceId = deviceId
            self.appInstanceId = appInstanceId
            self.tag = tag
            self.platform = platform
        }
    }

    /// Session-mode target: the broker origin plus this endpoint's
    /// registration coordinates. No Stack fields by design — the session
    /// token provider owns authentication.
    public struct SessionConfig: Sendable {
        public var baseUrl: String
        public var deviceId: String
        public var appInstanceId: String
        public var tag: String
        public var platform: String

        public init(
            baseUrl: String, deviceId: String, appInstanceId: String,
            tag: String, platform: String
        ) {
            self.baseUrl = baseUrl
            self.deviceId = deviceId
            self.appInstanceId = appInstanceId
            self.tag = tag
            self.platform = platform
        }
    }

    /// One coherent token pair from an already signed-in Stack session.
    public struct SessionTokens: Sendable {
        public let accessToken: String
        public let refreshToken: String

        public init(accessToken: String, refreshToken: String) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }
    }

    public struct Credential: Sendable {
        public let relayUrl: String
        public let token: String
        public let expiresAt: Int64?
    }

    public enum BrokerError: Error, CustomStringConvertible {
        case http(String, Int, String)
        case shape(String)
        /// Session mode only: the token provider reported no signed-in
        /// session. Fail closed — never mint as a guessed account.
        case notSignedIn

        public var description: String {
            switch self {
            case .http(let step, let code, let body):
                return "\(step) failed: HTTP \(code) \(body.prefix(200))"
            case .shape(let what):
                return "unexpected response shape: \(what)"
            case .notSignedIn:
                return "no signed-in session; cannot mint relay credentials"
            }
        }
    }

    private enum Authentication: Sendable {
        case password(
            stackBase: String, projectId: String, pck: String,
            email: String, password: String)
        case session(@Sendable () async throws -> SessionTokens?)
    }

    /// One HTTP round trip. Injectable so package tests can script the
    /// broker offline; production uses the shared session.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let baseUrl: String
    private let deviceId: String
    private let appInstanceId: String
    private let tag: String
    private let platform: String
    private let authentication: Authentication
    private let identity: PeerIdentity
    private let transport: Transport

    /// Password mode (dev harnesses and env-injected dogfood launches).
    public init(config: Config, identity: PeerIdentity) {
        self.init(config: config, identity: identity, transport: Self.liveTransport)
    }

    init(config: Config, identity: PeerIdentity, transport: @escaping Transport) {
        baseUrl = config.baseUrl
        deviceId = config.deviceId
        appInstanceId = config.appInstanceId
        tag = config.tag
        platform = config.platform
        authentication = .password(
            stackBase: config.stackBase, projectId: config.stackProjectId,
            pck: config.stackPck, email: config.email, password: config.password)
        self.identity = identity
        self.transport = transport
    }

    /// Session mode: mint through an existing signed-in Stack session.
    /// `tokens` returns the CURRENT pair (re-read per mint), or nil when
    /// definitively signed out.
    public init(
        sessionConfig: SessionConfig,
        tokens: @escaping @Sendable () async throws -> SessionTokens?,
        identity: PeerIdentity
    ) {
        self.init(
            sessionConfig: sessionConfig, tokens: tokens, identity: identity,
            transport: Self.liveTransport)
    }

    init(
        sessionConfig: SessionConfig,
        tokens: @escaping @Sendable () async throws -> SessionTokens?,
        identity: PeerIdentity,
        transport: @escaping Transport
    ) {
        baseUrl = sessionConfig.baseUrl
        deviceId = sessionConfig.deviceId
        appInstanceId = sessionConfig.appInstanceId
        tag = sessionConfig.tag
        platform = sessionConfig.platform
        authentication = .session(tokens)
        self.identity = identity
        self.transport = transport
    }

    private static let liveTransport: Transport = { request in
        try await URLSession.shared.data(for: request)
    }

    /// Compact mode name for diagnostics.
    private var authenticationModeName: String {
        switch authentication {
        case .password: return "password"
        case .session: return "session"
        }
    }

    /// Full mint: returns one credential per fleet relay; `preferredUrl`
    /// (the rendezvous relay from the ticket) is first when present.
    public func mint(preferredUrl: String?) async throws -> [Credential] {
        let endpointId = identity.publicKeyData.map { String(format: "%02x", $0) }.joined()
        let mintStart = ContinuousClock.now
        if TransportDebugLog.enabled {
            TransportDebugLog.broker.notice(
                """
                broker mint begin mode=\(self.authenticationModeName, privacy: .public) \
                device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public) \
                endpoint=\(TransportDebugLog.prefix(endpointId), privacy: .public) \
                base=\(self.baseUrl, privacy: .public) \
                preferred=\(preferredUrl ?? "none", privacy: .public)
                """)
        }

        // 1. Authenticate: password sign-in, or the app's live session pair.
        let authed = try await authenticatedHeaders()
        if TransportDebugLog.enabled {
            TransportDebugLog.broker.notice(
                """
                broker mint authenticated mode=\(self.authenticationModeName, privacy: .public) \
                device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public) \
                elapsedMs=\(TransportDebugLog.ms(since: mintStart), privacy: .public)
                """)
        }

        // 2. Registration payload; hash OUR exact bytes.
        let payload: JSONValue = .object([
            "route_contract_version": .int(1),
            "deviceId": .string(deviceId),
            "appInstanceId": .string(appInstanceId),
            "tag": .string(tag),
            "platform": .string(platform),
            "endpointId": .string(endpointId),
            "identityGeneration": .int(1),
            "pairingEnabled": .bool(false),
            "capabilities": .array([.string("cmux.testbed")]),
            "pathHints": .array([]),
        ])
        let payloadBytes = try JSONEncoder().encode(payload)
        let payloadB64 = base64url(payloadBytes)
        let payloadSha = SHA256.hash(data: payloadBytes)
            .map { String(format: "%02x", $0) }.joined()

        // 3. Challenge.
        let challenge = try await post(
            "\(baseUrl)/api/devices/iroh/challenge", headers: authed,
            body: [
                "deviceId": .string(deviceId),
                "appInstanceId": .string(appInstanceId),
                "tag": .string(tag),
                "endpointId": .string(endpointId),
                "identityGeneration": .int(1),
                "payloadSha256": .string(payloadSha),
            ], step: "broker challenge")
        guard let challengeId = challenge["challenge_id"]?.stringValue,
            let nonce = challenge["nonce"]?.stringValue
        else { throw BrokerError.shape("challenge fields") }

        // 4. Sign the transcript with the endpoint's own key.
        let transcript = Data(
            "cmux/iroh/device-registration/v1\n\(challengeId)\n\(nonce)\n\(payloadSha)".utf8)
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: identity.privateKeyData)
        let signature = base64url(try key.signature(for: transcript))

        // 5. Register; an endpoint already bound to this account is success.
        var registered: [String: JSONValue] = [:]
        do {
            registered = try await post(
                "\(baseUrl)/api/devices/iroh/register", headers: authed,
                body: [
                    "challengeId": .string(challengeId),
                    "nonce": .string(nonce),
                    "payload": .string(payloadB64),
                    "signature": .string(signature),
                ], step: "broker register")
        } catch let error as BrokerError {
            guard case .http(_, _, let body) = error,
                body.contains("endpoint_already_bound")
            else { throw error }
            if TransportDebugLog.enabled {
                TransportDebugLog.broker.notice(
                    """
                    broker register: endpoint already bound (treated as success) \
                    endpoint=\(TransportDebugLog.prefix(endpointId), privacy: .public)
                    """)
            }
        }

        // 6. Short-token issuance (register may bootstrap one directly).
        var credentials: [Credential] = []
        if registered["relay"]?.objectValue?["status"]?.stringValue == "issued",
            let token = registered["relay"]?.objectValue?["token"]?.stringValue
        {
            let relays = registered["relay"]?.objectValue?["relay_fleet"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
            credentials = relays.map {
                Credential(relayUrl: $0, token: token, expiresAt: nil)
            }
        } else {
            let minted = try await post(
                "\(baseUrl)/api/relay/token", headers: authed,
                body: ["endpointId": .string(endpointId)], step: "relay token")
            if let list = minted["relayCredentials"]?.arrayValue {
                credentials = list.compactMap { entry in
                    guard let object = entry.objectValue,
                        let url = object["relayUrl"]?.stringValue,
                        let token = object["token"]?.stringValue
                    else { return nil }
                    return Credential(
                        relayUrl: url, token: token,
                        expiresAt: object["expiresAt"]?.intValue)
                }
            } else if let token = minted["token"]?.stringValue {
                let relays = minted["relays"]?.arrayValue?.compactMap(\.stringValue) ?? []
                credentials = relays.map {
                    Credential(relayUrl: $0, token: token, expiresAt: minted["expiresAt"]?.intValue)
                }
            }
        }
        guard !credentials.isEmpty else {
            if TransportDebugLog.enabled {
                TransportDebugLog.broker.error(
                    """
                    broker mint FAILED mode=\(self.authenticationModeName, privacy: .public) \
                    device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public) \
                    cause=no-credentials-issued \
                    elapsedMs=\(TransportDebugLog.ms(since: mintStart), privacy: .public)
                    """)
            }
            throw BrokerError.shape("no credentials issued")
        }
        if let preferredUrl, let index = credentials.firstIndex(
            where: { $0.relayUrl == preferredUrl })
        {
            credentials.swapAt(0, index)
        }
        if TransportDebugLog.enabled {
            let first = credentials[0]
            TransportDebugLog.broker.notice(
                """
                broker mint SUCCESS mode=\(self.authenticationModeName, privacy: .public) \
                device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public) \
                relays=\(credentials.count, privacy: .public) \
                first=\(first.relayUrl, privacy: .public) \
                expiresAt=\(first.expiresAt.map(String.init) ?? "unset", privacy: .public) \
                tokenExp=\(IrohSubstrate.tokenExpiry(first.token).map(String.init) ?? "unparsed", privacy: .public) \
                tokenBoundToUs=\(IrohSubstrate.tokenEndpointId(first.token) == self.identity.publicKeyData, privacy: .public) \
                elapsedMs=\(TransportDebugLog.ms(since: mintStart), privacy: .public)
                """)
        }
        return credentials
    }

    /// The authenticated headers every broker request carries, resolved per
    /// mint so session-mode token rotation is always current.
    private func authenticatedHeaders() async throws -> [String: String] {
        switch authentication {
        case .password(let stackBase, let projectId, let pck, let email, let password):
            let signIn = try await post(
                "\(stackBase)/api/v1/auth/password/sign-in",
                headers: [
                    "content-type": "application/json",
                    "x-stack-project-id": projectId,
                    "x-stack-publishable-client-key": pck,
                    "x-stack-access-type": "client",
                ],
                body: ["email": .string(email), "password": .string(password)],
                step: "stack sign-in")
            guard let access = signIn["access_token"]?.stringValue,
                let refresh = signIn["refresh_token"]?.stringValue
            else { throw BrokerError.shape("sign-in tokens") }
            return Self.authedHeaders(access: access, refresh: refresh)
        case .session(let tokens):
            guard let pair = try await tokens() else {
                if TransportDebugLog.enabled {
                    TransportDebugLog.broker.error(
                        """
                        broker auth FAILED mode=session \
                        device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public) \
                        cause=not-signed-in (failing closed, no mint)
                        """)
                }
                throw BrokerError.notSignedIn
            }
            return Self.authedHeaders(
                access: pair.accessToken, refresh: pair.refreshToken)
        }
    }

    private static func authedHeaders(
        access: String, refresh: String
    ) -> [String: String] {
        [
            "content-type": "application/json",
            "authorization": "Bearer \(access)",
            "x-stack-refresh-token": refresh,
        ]
    }

    private func post(
        _ url: String, headers: [String: String], body: [String: JSONValue], step: String
    ) async throws -> [String: JSONValue] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if TransportDebugLog.enabled {
                TransportDebugLog.broker.error(
                    """
                    broker step FAILED step=\(step, privacy: .public) \
                    status=\(status, privacy: .public) \
                    device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public) \
                    bodyPrefix=\(String((String(data: data, encoding: .utf8) ?? "").prefix(120)), privacy: .public)
                    """)
            }
            throw BrokerError.http(step, status, String(data: data, encoding: .utf8) ?? "")
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.broker.notice(
                """
                broker step ok step=\(step, privacy: .public) \
                status=\(status, privacy: .public) \
                device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public)
                """)
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue ?? [:]
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
