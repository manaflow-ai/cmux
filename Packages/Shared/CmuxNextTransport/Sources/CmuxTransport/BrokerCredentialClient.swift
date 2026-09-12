import CryptoKit
import CMUXMobileCore
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
    enum Authentication: Sendable {
        case password(
            stackBase: String, projectId: String, pck: String,
            email: String, password: String)
        case session(@Sendable () async throws -> SessionTokens?)
    }

    /// One HTTP round trip. Injectable so package tests can script the
    /// broker offline; production owns one session per client.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let baseUrl: String
    let deviceId: String
    private let appInstanceId: String
    private let tag: String
    private let platform: String
    let authentication: Authentication
    let identity: PeerIdentity
    let transport: Transport

    /// Password mode (dev harnesses and env-injected dogfood launches).
    ///
    /// Prefer `init(environment:identity:auth:)` with
    /// `NextTransportEnvironment` + `.password`; this initializer is
    /// retained for source compatibility with existing call sites.
    public init(config: Config, identity: PeerIdentity) {
        self.init(config: config, identity: identity, transport: Self.liveTransport())
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
            transport: Self.liveTransport())
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
            platform: platform, transport: Self.liveTransport())
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

    static func liveTransport(configuration: sending URLSessionConfiguration = .ephemeral) -> Transport {
        let session = CmxCredentialedHTTPSession(configuration: configuration)
        return { request in try await session.data(for: request) }
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
    #if compiler(>=6.2)
    @concurrent
    #endif
    public nonisolated func mint(preferredUrl: String?) async throws -> [Credential] {
        let endpointId = HexEncoding().lowercase(identity.publicKeyData)
        let mintStart = ContinuousClock.now
        if TransportDebugLog.enabled {
            TransportDebugLog.broker.notice(
                """
                broker mint begin mode=\(self.authenticationModeName, privacy: .public) \
                device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public) \
                endpoint=\(TransportDebugLog.prefix(endpointId), privacy: .public) \
                base=\(Self.diagnosticOrigin(self.baseUrl), privacy: .public) \
                preferred=\(preferredUrl.map(Self.diagnosticOrigin) ?? "none", privacy: .public)
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
        let payloadSha = HexEncoding().lowercase(SHA256.hash(data: payloadBytes))

        // 3. Challenge.
        let challenge = try await post(
            base: baseUrl, path: "/api/devices/iroh/challenge", headers: authed,
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
                base: baseUrl, path: "/api/devices/iroh/register", headers: authed,
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
                base: baseUrl, path: "/api/relay/token", headers: authed,
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
        credentials = try validatedCredentials(credentials)
        if TransportDebugLog.enabled {
            let first = credentials[0]
            TransportDebugLog.broker.notice(
                """
                broker mint SUCCESS mode=\(self.authenticationModeName, privacy: .public) \
                device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public) \
                relays=\(credentials.count, privacy: .public) \
                first=\(first.relayUrl, privacy: .public) \
                expiresAt=\(first.expiresAt.map(String.init) ?? "unset", privacy: .public) \
                tokenExp=\(IrohSubstrate().tokenExpiry(first.token).map(String.init) ?? "unparsed", privacy: .public) \
                tokenBoundToUs=\(IrohSubstrate().tokenEndpointId(first.token) == self.identity.publicKeyData, privacy: .public) \
                elapsedMs=\(TransportDebugLog.ms(since: mintStart), privacy: .public)
                """)
        }
        return credentials
    }

}
