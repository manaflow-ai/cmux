public import CMUXMobileCore
public import Foundation

/// Supplies the short-lived Stack credentials required by native API calls.
public struct CmxIrohBrokerTokenSource: Sendable {
    public let accessToken: @Sendable () async -> String?
    public let refreshToken: @Sendable () async -> String?

    public init(
        accessToken: @escaping @Sendable () async -> String?,
        refreshToken: @escaping @Sendable () async -> String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

/// Injectable URL-loading boundary used by the trust broker client.
protocol CmxIrohHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Production URLSession implementation of ``CmxIrohHTTPTransport``.
struct CmxIrohURLSessionTransport: CmxIrohHTTPTransport {
    private let session: CmxCredentialedHTTPSession

    init(configuration: sending URLSessionConfiguration = .ephemeral) {
        session = CmxCredentialedHTTPSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Authenticated client for endpoint registration, discovery, grants, and relay tokens.
public actor CmxIrohTrustBrokerClient: CmxIrohRelayPolicyServing {
    private struct BindingRequest: Encodable { let bindingId: String }
    private struct EndpointRequest: Encodable { let endpointId: String }
    private struct RelayAccessCredential: Decodable {
        let relayUrl: String
        let token: String
        let expiresAt: Int64
        let refreshAfter: Int64
        let ttlSeconds: Int64
    }
    private struct RelayAccessResponse: Decodable {
        let token: String?
        let expiresAt: Int64?
        let ttlSeconds: Int64?
        let relays: [String]?
        let endpointId: String?
        let relayCredentials: [RelayAccessCredential]?
        let policy: String?
        let preference: CmxIrohAccountRelayConfiguration?
        let preferenceRevision: Int64?
    }
    private struct RelayTokenHeader: Decodable {
        let alg: String
        let typ: String
    }
    private struct RelayTokenClaims: Decodable {
        let issuer: String
        let audience: String
        let expiresAt: Int64
        let endpointID: String

        private enum CodingKeys: String, CodingKey {
            case issuer = "iss"
            case audience = "aud"
            case expiresAt = "exp"
            case endpointID = "endpoint_id"
        }
    }
    private struct PairGrantRequest: Encodable {
        let initiatorBindingId: String
        let acceptorBindingId: String
    }
    private struct RevokeResponse: Decodable {
        let revoked: Bool
        let lanRendezvousRotated: Bool

        private enum CodingKeys: String, CodingKey {
            case revoked
            case lanRendezvousRotated = "lan_rendezvous_rotated"
        }
    }
    private struct BrokerError: Decodable { let error: String }

    private let baseURL: URL
    private let tokenSource: CmxIrohBrokerTokenSource
    private let transport: any CmxIrohHTTPTransport
    private let requestTimeout: TimeInterval

    /// Creates a client that rejects cleartext non-loopback API origins.
    public init(
        baseURL: URL,
        tokenSource: CmxIrohBrokerTokenSource,
        requestTimeout: TimeInterval = 10
    ) throws {
        try self.init(
            baseURL: baseURL,
            tokenSource: tokenSource,
            transport: CmxIrohURLSessionTransport(),
            requestTimeout: requestTimeout
        )
    }

    /// Creates a client with an injected HTTP transport for isolation and testing.
    init(
        baseURL: URL,
        tokenSource: CmxIrohBrokerTokenSource,
        transport: any CmxIrohHTTPTransport,
        requestTimeout: TimeInterval = 10
    ) throws {
        guard Self.isAllowedBaseURL(baseURL), requestTimeout > 0 else {
            throw CmxIrohTrustBrokerClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.tokenSource = tokenSource
        self.transport = transport
        self.requestTimeout = requestTimeout
    }

    public func issueChallenge(
        _ request: CmxIrohChallengeRequest
    ) async throws -> CmxIrohChallengeResponse {
        try await send(path: "api/devices/iroh/challenge", method: "POST", body: request)
    }

    public func register(
        _ request: CmxIrohRegisterRequest
    ) async throws -> CmxIrohRegistrationResponse {
        try await send(path: "api/devices/iroh/register", method: "POST", body: request)
    }

    /// Runs the challenge and signed registration legs without regenerating payload bytes.
    public func register(
        prepared: CmxIrohPreparedRegistration,
        signer: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse {
        let challenge = try await issueChallenge(prepared.challengeRequest)
        let request = try signer.sign(prepared: prepared, challenge: challenge)
        return try await register(request)
    }

    public func discover() async throws -> CmxIrohDiscoveryResponse {
        try await sendWithoutBody(path: "api/devices/iroh", method: "GET")
    }

    public func issuePairGrant(
        initiatorBindingID: String,
        acceptorBindingID: String
    ) async throws -> CmxIrohPairGrantResponse {
        try await send(
            path: "api/devices/iroh/pair-grants",
            method: "POST",
            body: PairGrantRequest(
                initiatorBindingId: initiatorBindingID,
                acceptorBindingId: acceptorBindingID
            )
        )
    }

    public func issueEndpointAttestation(
        bindingID: String
    ) async throws -> CmxIrohEndpointAttestationResponse {
        try await send(
            path: "api/devices/iroh/endpoint-attestations",
            method: "POST",
            body: BindingRequest(bindingId: bindingID)
        )
    }

    public func issueRelayToken(
        bindingID _: String,
        endpointID: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRelayTokenResponse {
        let response: RelayAccessResponse = try await send(
            path: "api/relay/token",
            method: "POST",
            body: EndpointRequest(endpointId: endpointID.endpointID)
        )
        return try Self.relayTokenResponse(response, endpointID: endpointID)
    }

    /// Issues a managed credential together with signed, server-driven relay policy.
    public func issueRelayBootstrap(
        endpointID: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRelayBootstrapResponse {
        let response: RelayAccessResponse = try await send(
            path: "api/relay/token",
            method: "POST",
            body: EndpointRequest(endpointId: endpointID.endpointID)
        )
        guard let policy = response.policy,
              let preference = response.preference,
              let preferenceRevision = response.preferenceRevision else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        let policyResponse: CmxIrohRelayPolicyResponse
        do {
            policyResponse = try CmxIrohRelayPolicyResponse(
                policy: policy,
                preference: preference,
                preferenceRevision: preferenceRevision
            )
        } catch {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        let relayToken: CmxIrohRelayTokenResponse?
        if response.relayCredentials == nil, response.token == nil {
            relayToken = nil
        } else {
            relayToken = try Self.relayTokenResponse(response, endpointID: endpointID)
        }
        return CmxIrohRelayBootstrapResponse(
            relayToken: relayToken,
            relayPolicy: policyResponse
        )
    }

    /// Fetches the current account relay preference.
    public func relayPreference() async throws -> CmxIrohRelayPreferenceResponse {
        try await sendWithoutBody(path: "api/relay/preferences", method: "GET")
    }

    /// Replaces the current account relay preference using optimistic concurrency.
    public func updateRelayPreference(
        _ request: CmxIrohRelayPreferenceUpdateRequest
    ) async throws -> CmxIrohRelayPreferenceResponse {
        try await send(path: "api/relay/preferences", method: "PUT", body: request)
    }

    public func revoke(bindingID: String) async throws {
        let response: RevokeResponse = try await send(
            path: "api/devices/iroh",
            method: "DELETE",
            body: BindingRequest(bindingId: bindingID)
        )
        guard response.revoked, response.lanRendezvousRotated else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
    }

    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> Response {
        let encoded = try JSONEncoder().encode(body)
        return try await perform(path: path, method: method, body: encoded)
    }

    private func sendWithoutBody<Response: Decodable>(
        path: String,
        method: String
    ) async throws -> Response {
        try await perform(path: path, method: method, body: nil)
    }

    private func perform<Response: Decodable>(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Response {
        let accessToken = await tokenSource.accessToken()
        let refreshToken = await tokenSource.refreshToken()
        guard let accessToken, let refreshToken else {
            throw CmxIrohTrustBrokerClientError.missingAuthentication
        }
        guard Self.isSafeHeaderValue(accessToken), Self.isSafeHeaderValue(refreshToken) else {
            throw CmxIrohTrustBrokerClientError.invalidAuthentication
        }
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError where Self.isConnectivityFailure(error.code) {
            throw CmxIrohTrustBrokerClientError.connectivity
        }
        guard let http = response as? HTTPURLResponse else {
            throw CmxIrohTrustBrokerClientError.nonHTTPResponse
        }
        guard http.url == url else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let code = try? JSONDecoder().decode(BrokerError.self, from: data).error
            if http.statusCode == 429,
               let retryAfterSeconds = Self.retryAfterSeconds(
                   http.value(forHTTPHeaderField: "Retry-After")
               ) {
                throw CmxIrohTrustBrokerClientError.rateLimited(
                    code: code,
                    retryAfterSeconds: retryAfterSeconds
                )
            }
            throw CmxIrohTrustBrokerClientError.rejected(
                statusCode: http.statusCode,
                code: code
            )
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(CmxIrohISO8601Date.decode)
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
    }

    private static func isAllowedBaseURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        if scheme == "https" { return true }
        return scheme == "http" && ["127.0.0.1", "::1", "localhost"].contains(host)
    }

    private static func isSafeHeaderValue(_ value: String) -> Bool {
        (1 ... 16 * 1_024).contains(value.utf8.count)
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }

    private static func retryAfterSeconds(_ value: String?) -> Int? {
        guard let value,
              !value.isEmpty,
              value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let seconds = Int(value),
              (1 ... 3_600).contains(seconds),
              String(seconds) == value else {
            return nil
        }
        return seconds
    }

    private static func relayTokenResponse(
        _ response: RelayAccessResponse,
        endpointID: CmxIrohPeerIdentity
    ) throws -> CmxIrohRelayTokenResponse {
        if let credentials = response.relayCredentials {
            guard response.endpointId == endpointID.endpointID,
                  (1 ... CmxIrohRelayPolicyVerifier.maximumRelayCount).contains(
                      credentials.count
                  ) else {
                throw CmxIrohTrustBrokerClientError.invalidResponse
            }
            let relayCredentials = try credentials.map { credential in
                guard (30 ... 24 * 60 * 60).contains(credential.ttlSeconds),
                      credential.expiresAt > credential.refreshAfter,
                      credential.refreshAfter
                          >= credential.expiresAt - credential.ttlSeconds,
                      (1 ... 8 * 1_024).contains(credential.token.utf8.count) else {
                    throw CmxIrohTrustBrokerClientError.invalidResponse
                }
                return CmxIrohManagedRelayCredential(
                    relayURL: try canonicalRelayOrigin(credential.relayUrl),
                    token: credential.token,
                    expiresAt: iso8601(epochSeconds: credential.expiresAt),
                    refreshAfter: iso8601(epochSeconds: credential.refreshAfter)
                )
            }
            guard Set(relayCredentials.map(\.relayURL)).count
                    == relayCredentials.count else {
                throw CmxIrohTrustBrokerClientError.invalidResponse
            }
            return CmxIrohRelayTokenResponse(credentials: relayCredentials)
        }

        guard let token = response.token,
              let expiresAtSeconds = response.expiresAt,
              let ttlSeconds = response.ttlSeconds,
              let relays = response.relays,
              ttlSeconds == 300,
              expiresAtSeconds > ttlSeconds,
              (1 ... CmxIrohRelayPolicyVerifier.maximumRelayCount).contains(
                  relays.count
              ),
              validRelayToken(
                  token,
                  expiresAt: expiresAtSeconds,
                  endpointID: endpointID
              ) else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        let relayFleet = try relays.map(canonicalRelayOrigin)
        guard Set(relayFleet).count == relayFleet.count else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        let refreshLead = min(60, ttlSeconds / 2)
        return CmxIrohRelayTokenResponse(
            token: token,
            expiresAt: iso8601(epochSeconds: expiresAtSeconds),
            refreshAfter: iso8601(epochSeconds: expiresAtSeconds - refreshLead),
            relayFleet: relayFleet
        )
    }

    private static func iso8601(epochSeconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        )
    }

    private static func validRelayToken(
        _ token: String,
        expiresAt: Int64,
        endpointID: CmxIrohPeerIdentity
    ) -> Bool {
        guard (1 ... 8 * 1_024).contains(token.utf8.count) else { return false }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let headerData = base64URLData(segments[0]),
              let claimsData = base64URLData(segments[1]),
              let header = try? JSONDecoder().decode(RelayTokenHeader.self, from: headerData),
              let claims = try? JSONDecoder().decode(RelayTokenClaims.self, from: claimsData) else {
            return false
        }
        return header.alg == "EdDSA"
            && header.typ == "JWT"
            && claims.issuer == "cmux"
            && claims.audience == "cmux-relay"
            && claims.expiresAt == expiresAt
            && claims.endpointID == endpointID.endpointID
    }

    private static func base64URLData(_ value: Substring) -> Data? {
        var encoded = String(value)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.utf8.count % 4
        if remainder != 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: encoded)
    }

    private static func canonicalRelayOrigin(_ value: String) throws -> String {
        guard var components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              host == host.lowercased(),
              !host.isEmpty,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        components.path = "/"
        guard let canonical = components.string else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        return canonical
    }

    private static func isConnectivityFailure(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .cannotLoadFromNetwork:
            true
        default:
            false
        }
    }
}
