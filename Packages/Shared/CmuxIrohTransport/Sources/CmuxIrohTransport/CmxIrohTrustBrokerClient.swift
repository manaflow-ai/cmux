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
public protocol CmxIrohHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Production URLSession implementation of ``CmxIrohHTTPTransport``.
public struct CmxIrohURLSessionTransport: CmxIrohHTTPTransport {
    private let session: URLSession

    public init(session: sending URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Authenticated client for endpoint registration, discovery, grants, and relay tokens.
public actor CmxIrohTrustBrokerClient {
    private struct BindingRequest: Encodable { let bindingId: String }
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
        session: sending URLSession = .shared,
        requestTimeout: TimeInterval = 10
    ) throws {
        try self.init(
            baseURL: baseURL,
            tokenSource: tokenSource,
            transport: CmxIrohURLSessionTransport(session: session),
            requestTimeout: requestTimeout
        )
    }

    /// Creates a client with an injected HTTP transport for isolation and testing.
    public init(
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
        bindingID: String
    ) async throws -> CmxIrohRelayTokenResponse {
        try await send(
            path: "api/devices/iroh/relay-token",
            method: "POST",
            body: BindingRequest(bindingId: bindingID)
        )
    }

    public func revoke(bindingID: String) async throws {
        let response: RevokeResponse = try await send(
            path: "api/devices/iroh/revoke",
            method: "POST",
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
        guard (200 ... 299).contains(http.statusCode) else {
            let code = try? JSONDecoder().decode(BrokerError.self, from: data).error
            throw CmxIrohTrustBrokerClientError.rejected(
                statusCode: http.statusCode,
                code: code
            )
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
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
