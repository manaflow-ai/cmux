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

    /// Account authentication for the environment-based entry point. Both
    /// modes delegate to the same broker flow the legacy `Config` and
    /// `SessionConfig` initializers drive.
    public enum Auth: Sendable {
        /// Dev harnesses: mint a fresh Stack session from a password pair.
        case password(email: String, password: String)
        /// Production shape: the app's already signed-in Stack session
        /// supplies the CURRENT pair per mint; nil fails closed
        /// (`BrokerError.notSignedIn`), never minting as a guessed account.
        case session(tokens: @Sendable () async throws -> SessionTokens?)
    }

    public struct Credential: Sendable {
        public let relayUrl: String
        public let token: String
        public let expiresAt: Int64?
    }

    public enum BrokerError: Error, CustomStringConvertible {
        /// An HTTP step failed. Carries only redaction-safe fields: the
        /// step name, status code, request URL path (never the query), and
        /// the short stable error code the broker returns as JSON
        /// `{"error": <code>}` (web/services/iroh/routeHandler.ts) when one
        /// parses. Raw response bodies can echo access/refresh tokens, so
        /// they are never stored, logged, or rendered.
        case http(step: String, status: Int, path: String, code: String?)
        /// A request URL could not be built from the configured base URL.
        /// Carries the offending URL up to (never including) any query.
        case malformedURL(step: String, url: String)
        case shape(String)
        /// Session mode only: the token provider reported no signed-in
        /// session. Fail closed — never mint as a guessed account.
        case notSignedIn

        public var description: String {
            switch self {
            case .http(let step, let status, let path, let code):
                let suffix = code.map { " error=\($0)" } ?? ""
                return "\(step) failed: HTTP \(status) path=\(path)\(suffix)"
            case .malformedURL(let step, let url):
                return "\(step) failed: malformed request URL \(url)"
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
    ///
    /// Prefer `init(environment:identity:auth:)` with
    /// `NextTransportEnvironment` + `.password`; this initializer is
    /// retained for source compatibility with existing call sites.
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
    ///
    /// Prefer `init(environment:identity:auth:)` with
    /// `NextTransportEnvironment` + `.session`; this initializer is
    /// retained for source compatibility with existing call sites.
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

    /// Environment-based entry point: one `NextTransportEnvironment`
    /// supplies every broker/Stack coordinate, and `Auth` picks the
    /// authentication mode. Registration coordinates default from the
    /// identity (`deviceId`/`appInstanceId` = `identity.deviceID`) and the
    /// build platform, so most call sites pass only the first three
    /// arguments plus their `tag`.
    public init(
        environment: NextTransportEnvironment,
        identity: PeerIdentity,
        auth: Auth,
        deviceId: String? = nil,
        appInstanceId: String? = nil,
        tag: String? = nil,
        platform: String? = nil
    ) {
        self.init(
            environment: environment, identity: identity, auth: auth,
            deviceId: deviceId, appInstanceId: appInstanceId, tag: tag,
            platform: platform, transport: Self.liveTransport)
    }

    init(
        environment: NextTransportEnvironment,
        identity: PeerIdentity,
        auth: Auth,
        deviceId: String? = nil,
        appInstanceId: String? = nil,
        tag: String? = nil,
        platform: String? = nil,
        transport: @escaping Transport
    ) {
        let deviceId = deviceId ?? identity.deviceID
        let appInstanceId = appInstanceId ?? identity.deviceID
        let tag = tag ?? "next-transport"
        let platform = platform ?? Self.buildPlatform
        switch auth {
        case .password(let email, let password):
            self.init(
                config: Config(
                    baseUrl: environment.brokerBaseURL.absoluteString,
                    stackBase: environment.stackAuthBaseURL.absoluteString,
                    stackProjectId: environment.stackProjectID,
                    stackPck: environment.stackPublishableClientKey,
                    email: email, password: password,
                    deviceId: deviceId, appInstanceId: appInstanceId,
                    tag: tag, platform: platform),
                identity: identity, transport: transport)
        case .session(let tokens):
            self.init(
                sessionConfig: SessionConfig(
                    baseUrl: environment.brokerBaseURL.absoluteString,
                    deviceId: deviceId, appInstanceId: appInstanceId,
                    tag: tag, platform: platform),
                tokens: tokens, identity: identity, transport: transport)
        }
    }

    private static var buildPlatform: String {
        #if os(iOS)
        return "ios"
        #else
        return "mac"
        #endif
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
            guard case .http(_, _, _, let code) = error, code == Self.alreadyBoundCode
            else { throw error }
            if TransportDebugLog.enabled {
                TransportDebugLog.broker.notice(
                    """
                    broker register: endpoint already bound (treated as success) \
                    endpoint=\(TransportDebugLog.prefix(endpointId), privacy: .public)
                    """)
            }
        }

        // 6. Short-token issuance. /register bootstraps a token on FIRST
        // registration only (web/services/iroh/trustBroker.ts): its
        // relay grant carries status "issued" with token/expires_at/
        // relay_fleet, while "unavailable" (server-side mint failed) and
        // "not_requested" (refresh) carry no token. An already-bound
        // register (caught above, `registered` deliberately left empty)
        // holds no grant either. Only a usable issued grant skips the
        // explicit /api/relay/token mint below.
        let grant = registered["relay"]?.objectValue
        let grantStatus = grant?["status"]?.stringValue
        var credentials: [Credential] = []
        if grantStatus == "issued", let token = grant?["token"]?.stringValue {
            let serverExpiry = (grant?["expires_at"]?.stringValue)
                .flatMap(Self.epochSeconds(iso8601:))
            credentials = (grant?["relay_fleet"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                .map { Self.credential(relayUrl: $0, token: token, serverExpiresAt: serverExpiry) }
        }
        if TransportDebugLog.enabled {
            let outcome = credentials.isEmpty
                ? "needs-mint reason=\(grantStatus ?? (registered.isEmpty ? "empty-register-response" : "no-relay-grant"))"
                : "bootstrapped relays=\(credentials.count)"
            TransportDebugLog.broker.notice(
                """
                broker register outcome=\(outcome, privacy: .public) \
                device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public)
                """)
        }
        if credentials.isEmpty {
            let minted = try await post(
                "\(baseUrl)/api/relay/token", headers: authed,
                body: ["endpointId": .string(endpointId)], step: "relay token")
            if let list = minted["relayCredentials"]?.arrayValue {
                credentials = list.compactMap { entry in
                    guard let object = entry.objectValue,
                        let url = object["relayUrl"]?.stringValue,
                        let token = object["token"]?.stringValue
                    else { return nil }
                    return Self.credential(
                        relayUrl: url, token: token,
                        serverExpiresAt: object["expiresAt"]?.intValue)
                }
            } else if let token = minted["token"]?.stringValue {
                let relays = minted["relays"]?.arrayValue?.compactMap(\.stringValue) ?? []
                credentials = relays.map {
                    Self.credential(
                        relayUrl: $0, token: token,
                        serverExpiresAt: minted["expiresAt"]?.intValue)
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
        // Only absolute http(s) URLs may carry the auth headers; anything
        // else (a mangled base URL, a scheme-less fragment) is a typed
        // error instead of a force-unwrap crash.
        guard let requestUrl = URL(string: url),
            let scheme = requestUrl.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            requestUrl.host != nil
        else {
            throw BrokerError.malformedURL(
                step: step, url: String(url.prefix(while: { $0 != "?" })))
        }
        var request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = Self.serverErrorCode(in: data)
            if TransportDebugLog.enabled {
                TransportDebugLog.broker.error(
                    """
                    broker step FAILED step=\(step, privacy: .public) \
                    status=\(status, privacy: .public) \
                    path=\(requestUrl.path, privacy: .public) \
                    error=\(code ?? "unparsed", privacy: .public) \
                    device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public)
                    """)
            }
            throw BrokerError.http(
                step: step, status: status, path: requestUrl.path, code: code)
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

    static let alreadyBoundCode = "endpoint_already_bound"

    /// The short stable error code from a broker error body. The broker
    /// always answers `{"error": <code>}` (web/services/iroh/
    /// routeHandler.ts); the code is still server-controlled text, so
    /// anything long or outside the code alphabet is dropped rather than
    /// propagated into errors and logs.
    static func serverErrorCode(in data: Data) -> String? {
        if let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue,
            let code = object["error"]?.stringValue, Self.isSafeErrorCode(code)
        {
            return code
        }
        // Last-resort fallback for a non-JSON body (a proxy error page, a
        // legacy broker): the one code the mint flow must still recognize
        // is endpoint_already_bound, so scan for exactly that token.
        if let text = String(data: data, encoding: .utf8),
            text.contains(Self.alreadyBoundCode)
        {
            return Self.alreadyBoundCode
        }
        return nil
    }

    private static func isSafeErrorCode(_ code: String) -> Bool {
        guard !code.isEmpty, code.count <= 64 else { return false }
        return code.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".")
        }
    }

    /// Builds a credential whose `expiresAt` is ALWAYS populated when
    /// knowable: the server-provided expiry first, else the token's own JWT
    /// `exp` claim, so `RelayCredentialSchedule` gets a real deadline
    /// instead of the blind fallback cadence whenever one exists.
    private static func credential(
        relayUrl: String, token: String, serverExpiresAt: Int64?
    ) -> Credential {
        Credential(
            relayUrl: relayUrl, token: token,
            expiresAt: serverExpiresAt ?? IrohSubstrate.tokenExpiry(token))
    }

    /// Epoch seconds from the broker's ISO-8601 timestamps
    /// (`Date.toISOString()` emits fractional seconds; tolerate both).
    static func epochSeconds(iso8601 value: String) -> Int64? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return Int64(date.timeIntervalSince1970)
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value).map { Int64($0.timeIntervalSince1970) }
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
