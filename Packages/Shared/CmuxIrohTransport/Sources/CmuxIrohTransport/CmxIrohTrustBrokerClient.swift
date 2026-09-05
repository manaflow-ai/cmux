public import CMUXMobileCore
public import Foundation

private let cmxIrohSessionTicketHeader = "x-cmux-iroh-session-ticket"

private func cmxIsSafeClientNamespace(_ value: String) -> Bool {
    (1 ... 255).contains(value.utf8.count)
        && value.utf8.allSatisfy {
            (48 ... 57).contains($0)
                || (65 ... 90).contains($0)
                || (97 ... 122).contains($0)
                || [45, 46, 58, 95].contains($0)
        }
}

private func cmxIsSafeBrokerHeaderValue(_ value: String) -> Bool {
    (1 ... 16 * 1_024).contains(value.utf8.count)
        && !value.unicodeScalars.contains(
            where: { $0.value < 0x20 || $0.value == 0x7f }
        )
}

/// One access + refresh credential pair captured from a single session snapshot.
///
/// Assembling a request from one snapshot prevents pairing a stale access token
/// with a freshly-rotated refresh token (or vice versa) when a force refresh
/// lands between two independent token reads.
public struct CmxIrohBrokerCredentials: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String

    public init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    /// Redacted: the synthesized reflection would copy live bearer/refresh
    /// tokens into logs, assertion output, and crash reports.
    public var description: String {
        "CmxIrohBrokerCredentials(accessToken: <redacted>, refreshToken: <redacted>)"
    }

    public var debugDescription: String { description }
}

private func isUnsupportedRegistrationScope(
    _ error: CmxIrohTrustBrokerClientError
) -> Bool {
    guard case let .rejected(statusCode, code) = error else { return false }
    return statusCode == 400 && code == "unknown_field"
}

private func isMissingScopedDiscoveryRoute(
    _ error: CmxIrohTrustBrokerClientError
) -> Bool {
    guard case let .rejected(statusCode, _) = error else { return false }
    return statusCode == 404
}

/// One authenticated account and credential pair captured atomically.
///
/// Platform auth coordinators map their native session snapshot into this
/// transport-owned value so account pinning and exactly-once rejection
/// recovery stay identical on macOS and iOS.
public struct CmxIrohAccountCredentialSnapshot: Sendable {
    public let accountID: String
    public let credentials: CmxIrohBrokerCredentials

    public init(
        accountID: String,
        credentials: CmxIrohBrokerCredentials
    ) {
        self.accountID = accountID
        self.credentials = credentials
    }
}

/// Supplies the short-lived Stack credentials required by native API calls.
///
/// The ONLY construction input is `credentialPair`, which must return BOTH
/// tokens from ONE capture. Making the pair the required source removes the
/// torn-credential hazard structurally: a source assembled from two
/// independent token reads (where a session transition between them pairs one
/// session's access token with another's refresh token) is no longer
/// expressible. The single-token accessors are derived from the pair for
/// callers that need one token.
///
/// The pair read distinguishes two failure states. Returning `nil` means the
/// credentials are DEFINITIVELY absent (signed out, account switched) and the
/// broker fails closed with ``CmxIrohTrustBrokerClientError/missingAuthentication``.
/// Throwing means the source could not read a coherent pair RIGHT NOW (the
/// token store is owned by a launch/foreground revalidation, or an expired
/// access token's re-mint is in flight or offline); the broker classifies
/// that as ``CmxIrohTrustBrokerClientError/connectivity`` so callers retry and
/// cached-policy fallbacks apply instead of tearing trusted state down.
public struct CmxIrohBrokerTokenSource: Sendable {
    public let accessToken: @Sendable () async throws -> String?
    public let refreshToken: @Sendable () async throws -> String?
    /// Both tokens from ONE snapshot, so a request can never mix an old access
    /// token with a rotated refresh token.
    public let credentialPair: @Sendable () async throws -> CmxIrohBrokerCredentials?
    /// Replaces a pair the broker just rejected as unauthorized.
    ///
    /// A pair that was coherent at capture can still be rejected when another
    /// lane rotates the session between capture and server validation (the
    /// wake-time RPC force refresh, most commonly). Live sources force-mint
    /// through their session owner and return the replacement pair; frozen
    /// pinned sources (sign-out revocation) return nil so a destructive flow
    /// never silently switches credentials. The client retries the rejected
    /// request at most once with the recovered pair.
    public let recoveredCredentialPair:
        @Sendable (_ rejected: CmxIrohBrokerCredentials) async throws
            -> CmxIrohBrokerCredentials?

    public init(
        credentialPair: @escaping @Sendable () async throws -> CmxIrohBrokerCredentials?,
        recoveredCredentialPair: @escaping @Sendable (
            _ rejected: CmxIrohBrokerCredentials
        ) async throws -> CmxIrohBrokerCredentials? = { _ in nil }
    ) {
        self.credentialPair = credentialPair
        self.recoveredCredentialPair = recoveredCredentialPair
        self.accessToken = { try await credentialPair()?.accessToken }
        self.refreshToken = { try await credentialPair()?.refreshToken }
    }

    /// Builds a live token source pinned to one account.
    ///
    /// A rejected pair first re-reads the atomic session snapshot. If another
    /// lane already rotated it, that newer pair is reused. Otherwise the
    /// platform auth owner is asked to refresh once, followed by one final
    /// account-pinned snapshot. Account switches and missing sessions fail
    /// closed throughout.
    public static func accountPinned(
        to expectedAccountID: String,
        snapshot: @escaping @Sendable () async throws
            -> CmxIrohAccountCredentialSnapshot?,
        forceRefresh: @escaping @Sendable () async throws -> Void
    ) -> Self {
        Self(
            credentialPair: {
                guard let captured = try await snapshot(),
                      captured.accountID == expectedAccountID else {
                    return nil
                }
                return captured.credentials
            },
            recoveredCredentialPair: { rejected in
                do {
                    if let captured = try await snapshot(),
                       captured.accountID == expectedAccountID,
                       captured.credentials.accessToken != rejected.accessToken {
                        return captured.credentials
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A transient snapshot read can still be repaired by the
                    // one explicit refresh below.
                }
                do {
                    try await forceRefresh()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return nil
                }
                let refreshed: CmxIrohAccountCredentialSnapshot?
                do {
                    refreshed = try await snapshot()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return nil
                }
                guard let refreshed,
                      refreshed.accountID == expectedAccountID else { return nil }
                return refreshed.credentials
            }
        )
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
private struct DiscoverySnapshotChanged: Error {}

/// The proof fields carried by a control-plane relay-mint request. The
/// account Durable Object converts these into the normal HTTP proof headers,
/// preserving endpoint-key authorization on the socket shortcut.
public struct CmxIrohControlPlaneRequestProof: Equatable, Sendable {
    public let bindingID: String
    public let timestamp: String
    public let signature: String

    public init(bindingID: String, timestamp: String, signature: String) {
        self.bindingID = bindingID
        self.timestamp = timestamp
        self.signature = signature
    }
}

public actor CmxIrohTrustBrokerClient: CmxIrohRelayPolicyServing {
    private struct SessionResponse: Decodable, Sendable {
        let ticket: String
        let sessionId: String
        let accountId: String
        let expiresAt: Date
        let renewAfter: Date
    }

    private struct SessionState: Sendable {
        let ticket: String
        let sessionID: String
        let accountID: String
        let expiresAt: Date
        var renewAfter: Date
        var nextRenewAttempt: Date
    }

    private enum RequestAuthorization: Sendable {
        case stack(CmxIrohBrokerCredentials)
        case session(String)
    }

    private struct SessionBootstrapBody: Encodable {
        let deviceID: String
        let appInstanceID: String
        let clientNamespace: String
        let tag: String
        let platform: CmxIrohPlatform

        private enum CodingKeys: String, CodingKey {
            case deviceID = "deviceId"
            case appInstanceID = "appInstanceId"
            case clientNamespace
            case tag
            case platform
        }
    }

    private struct ConnectivitySyncRequest: Encodable {
        let protocolVersion: Int
        let knownRevision: UInt64?
        let discoveryScope: CmxConnectivityDiscoveryScope?

        private enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version"
            case knownRevision = "known_revision"
            case discoveryScope = "discovery_scope"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            if let knownRevision {
                try container.encode(knownRevision, forKey: .knownRevision)
            } else {
                // The wire contract distinguishes an initial sync (`null`)
                // from an absent field. Swift's synthesized Optional encoding
                // omits nil values, which the bounded server parser correctly
                // rejects as an incomplete request.
                try container.encodeNil(forKey: .knownRevision)
            }
            try container.encodeIfPresent(discoveryScope, forKey: .discoveryScope)
        }
    }

    private struct BindingRequest: Encodable { let bindingId: String }
    private struct EndpointRequest: Encodable { let endpointId: String }
    private struct RelayAccessCredential: Decodable, Sendable {
        let relayUrl: String
        let token: String
        let expiresAt: Int64
        let refreshAfter: Int64
        let ttlSeconds: Int64
    }
    private struct RelayAccessResponse: Decodable, Sendable {
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
    private struct RevokeResponse: Decodable, Sendable {
        let revoked: Bool
        let lanRendezvousRotated: Bool

        private enum CodingKeys: String, CodingKey {
            case revoked
            case lanRendezvousRotated = "lan_rendezvous_rotated"
        }
    }
    private let baseURL: URL
    private let tokenSource: CmxIrohBrokerTokenSource
    private let transport: any CmxIrohHTTPTransport
    private let requestTimeout: TimeInterval
    private let backpressureGate: CmxIrohBrokerBackpressureGate?
    private let clientNamespace: String
    private var bindingAuthorization: CmxIrohBindingRequestAuthorization?
    private let discoveryScope: CmxConnectivityDiscoveryScope?
    private let sessionConfiguration: CmxIrohSessionConfiguration?
    private var sessionState: SessionState?
    private var sessionUnsupported = false
    private var sessionRefreshInFlight: Task<String?, any Error>?

    /// Creates a client that rejects cleartext non-loopback API origins.
    public init(
        baseURL: URL,
        tokenSource: CmxIrohBrokerTokenSource,
        clientNamespace: String,
        bindingAuthorization: CmxIrohBindingRequestAuthorization? = nil,
        discoveryScope: CmxConnectivityDiscoveryScope? = nil,
        sessionConfiguration: CmxIrohSessionConfiguration? = nil,
        requestTimeout: TimeInterval = 10,
        backpressureMode: CmxIrohBrokerBackpressureMode = .automatic
    ) throws {
        try self.init(
            baseURL: baseURL,
            tokenSource: tokenSource,
            clientNamespace: clientNamespace,
            bindingAuthorization: bindingAuthorization,
            discoveryScope: discoveryScope,
            sessionConfiguration: sessionConfiguration,
            transport: CmxIrohURLSessionTransport(),
            requestTimeout: requestTimeout,
            backpressureMode: backpressureMode
        )
    }

    /// Creates a client with an injected HTTP transport for isolation and testing.
    init(
        baseURL: URL,
        tokenSource: CmxIrohBrokerTokenSource,
        clientNamespace: String,
        bindingAuthorization: CmxIrohBindingRequestAuthorization? = nil,
        discoveryScope: CmxConnectivityDiscoveryScope? = nil,
        sessionConfiguration: CmxIrohSessionConfiguration? = nil,
        transport: any CmxIrohHTTPTransport,
        requestTimeout: TimeInterval = 10,
        backpressureMode: CmxIrohBrokerBackpressureMode = .automatic
    ) throws {
        guard Self.isAllowedBaseURL(baseURL),
              cmxIsSafeClientNamespace(clientNamespace),
              bindingAuthorization?.clientNamespace == nil
                || bindingAuthorization?.clientNamespace == clientNamespace,
              sessionConfiguration.map(Self.isValidSessionConfiguration) ?? true,
              requestTimeout > 0 else {
            throw CmxIrohTrustBrokerClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.tokenSource = tokenSource
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.clientNamespace = clientNamespace
        self.bindingAuthorization = bindingAuthorization
        self.discoveryScope = discoveryScope
        self.sessionConfiguration = sessionConfiguration
        switch backpressureMode {
        case .automatic:
            backpressureGate = CmxIrohBrokerBackpressureGate()
        case .callerOwned:
            backpressureGate = nil
        }
    }

    public func preflight(operation: CmxIrohBrokerOperation) async throws {
        guard let backpressureGate else { return }
        try await backpressureGate.preflight(
            accountID: CmxIrohBrokerBackpressureGate.directClientScope,
            operation: operation
        )
    }

    /// Reports whether this client retains a signed binding request proof.
    public func hasBindingAuthorization() async -> Bool {
        bindingAuthorization != nil
    }

    /// Returns the binding ID represented by the retained request proof.
    public func bindingAuthorizationID() async -> String? {
        bindingAuthorization?.bindingID
    }

    /// Signs the exact body and path used by a control-plane request. The
    /// returned fields are safe to serialize into the control-plane proof
    /// envelope; the ordinary HTTP path uses the same signer internally.
    public func makeControlPlaneRequestProof(
        method: String,
        path: String,
        body: Data,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> CmxIrohControlPlaneRequestProof? {
        guard let bindingAuthorization else { return nil }
        let signature = try bindingAuthorization.signer.signBrokerRequest(
            bindingID: bindingAuthorization.bindingID,
            method: method,
            path: path,
            timestamp: timestamp,
            body: body
        )
        return CmxIrohControlPlaneRequestProof(
            bindingID: bindingAuthorization.bindingID,
            timestamp: String(timestamp),
            signature: signature
        )
    }

    /// Returns the current account-scoped Cloudflare session ticket, opening or
    /// renewing it when needed. `nil` means this client was constructed
    /// without session configuration or the configured origin does not expose
    /// the session endpoint yet, in which case callers use the legacy Stack
    /// credential path.
    ///
    /// The operation is single-flight inside this actor. A reconnect storm can
    /// therefore share one bootstrap or renewal request instead of asking
    /// Stack for a token pair once per socket or broker operation.
    public func ensureSessionTicket() async throws -> String? {
        guard sessionConfiguration != nil, !sessionUnsupported else { return nil }
        let now = Date()
        if let sessionState,
           sessionState.expiresAt.timeIntervalSince(now) > 5,
           (now < sessionState.renewAfter || now < sessionState.nextRenewAttempt) {
            return sessionState.ticket
        }
        if let sessionRefreshInFlight {
            return try await sessionRefreshInFlight.value
        }
        let task = Task<String?, any Error> { [weak self] in
            guard let self else { return nil }
            return try await self.refreshSessionTicket()
        }
        sessionRefreshInFlight = task
        defer { sessionRefreshInFlight = nil }
        return try await task.value
    }

    /// Invalidates the in-memory ticket after a server-side 401. The next
    /// request performs one fresh bootstrap using the Stack session.
    public func invalidateSessionTicket() {
        sessionState = nil
    }

    private static func isValidSessionConfiguration(
        _ configuration: CmxIrohSessionConfiguration
    ) -> Bool {
        func valid(_ value: String, maximum: Int = 255) -> Bool {
            !value.isEmpty && value.utf8.count <= maximum
                && !value.unicodeScalars.contains {
                    $0.value < 0x20 || $0.value == 0x7f
                }
        }
        return valid(configuration.deviceID)
            && valid(configuration.appInstanceID)
            && valid(configuration.clientNamespace)
            && valid(configuration.tag)
    }

    public func issueChallenge(
        _ request: CmxIrohChallengeRequest
    ) async throws -> CmxIrohChallengeResponse {
        try await send(
            path: "api/devices/iroh/challenge",
            method: "POST",
            body: request,
            operation: .registration
        )
    }

    public func register(
        _ request: CmxIrohRegisterRequest
    ) async throws -> CmxIrohRegistrationResponse {
        try await withBackpressure(operation: .registration) {
            try await self.registerUngated(request)
        }
    }

    /// Runs the challenge and signed registration legs without regenerating payload bytes.
    public func register(
        prepared: CmxIrohPreparedRegistration,
        signer: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse {
        let response: CmxIrohRegistrationResponse = try await withBackpressure(
            operation: .registration
        ) {
            let challenge: CmxIrohChallengeResponse = try await self.sendUngated(
                path: "api/devices/iroh/challenge",
                method: "POST",
                body: prepared.challengeRequest
            )
            let request = try signer.sign(prepared: prepared, challenge: challenge)
            return try await self.registerUngated(request)
        }
        bindingAuthorization = CmxIrohBindingRequestAuthorization(
            bindingID: response.binding.bindingID,
            clientNamespace: clientNamespace,
            signer: signer
        )
        return response
    }

    /// Discovers account bindings visible to this client's exact build namespace.
    public func discover() async throws -> CmxIrohDiscoveryResponse {
        try await withBackpressure(operation: .discovery) {
            if self.discoveryScope != nil {
                do {
                    let response = try await self.syncConnectivityUngated(
                        knownRevision: nil
                    )
                    if let snapshot = response.snapshot,
                       response.snapshotIsComplete {
                        return snapshot
                    }
                    if response.protocolVersion
                        == CmxConnectivitySyncResponse.scopedProtocolVersion {
                        throw CmxIrohTrustBrokerClientError.invalidResponse
                    }
                } catch let error as CmxIrohTrustBrokerClientError
                    where isMissingScopedDiscoveryRoute(error) {
                    // Older servers have only paginated global discovery.
                }
            }
            return try await self.discoverAllPages()
        }
    }

    /// Reconciles one completely installed route revision with connectivity v3,
    /// falling back to global connectivity v2 on older servers.
    public func syncConnectivity(
        knownRevision: UInt64?
    ) async throws -> CmxConnectivitySyncResponse {
        try await withBackpressure(operation: .discovery) {
            try await self.syncConnectivityUngated(knownRevision: knownRevision)
        }
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
            ),
            operation: .pairGrant
        )
    }

    public func issueEndpointAttestation(
        bindingID: String
    ) async throws -> CmxIrohEndpointAttestationResponse {
        try await send(
            path: "api/devices/iroh/endpoint-attestations",
            method: "POST",
            body: BindingRequest(bindingId: bindingID),
            operation: .endpointAttestation
        )
    }

    public func issueRelayToken(
        bindingID _: String,
        endpointID: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRelayTokenResponse {
        let response: RelayAccessResponse = try await send(
            path: "api/relay/token",
            method: "POST",
            body: EndpointRequest(endpointId: endpointID.endpointID),
            operation: .relayCredential
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
            body: EndpointRequest(endpointId: endpointID.endpointID),
            operation: .relayCredential
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
        try await sendWithoutBody(
            path: "api/relay/preferences",
            method: "GET",
            operation: .relayPreference
        )
    }

    /// Replaces the current account relay preference using optimistic concurrency.
    public func updateRelayPreference(
        _ request: CmxIrohRelayPreferenceUpdateRequest
    ) async throws -> CmxIrohRelayPreferenceResponse {
        try await send(
            path: "api/relay/preferences",
            method: "PUT",
            body: request,
            operation: .relayPreference
        )
    }

    /// Revokes the caller's own binding.
    public func revoke(bindingID: String) async throws {
        let response: RevokeResponse = try await send(
            path: "api/devices/iroh",
            method: "DELETE",
            body: BindingRequest(bindingId: bindingID),
            operation: .revocation
        )
        guard response.revoked, response.lanRendezvousRotated else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
    }

    /// Revokes an older binding owned by this app namespace and physical device.
    public func revokeStale(bindingID: String) async throws {
        let response: RevokeResponse = try await send(
            path: "api/devices/iroh",
            method: "DELETE",
            body: CmxIrohStaleBindingRevocationRequest(bindingId: bindingID),
            operation: .revocation
        )
        guard response.revoked, response.lanRendezvousRotated else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
    }

    /// Revokes one same-build Mac through the explicit account-management path.
    public func forgetMac(bindingID: String) async throws {
        let response: RevokeResponse = try await send(
            path: "api/devices/iroh",
            method: "DELETE",
            body: CmxIrohMacForgetRequest(bindingId: bindingID),
            operation: .revocation
        )
        guard response.revoked, response.lanRendezvousRotated else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
    }

    private func registerUngated(
        _ request: CmxIrohRegisterRequest
    ) async throws -> CmxIrohRegistrationResponse {
        guard let discoveryScope else {
            return try await sendUngated(
                path: "api/devices/iroh/register",
                method: "POST",
                body: request.including(discoveryScope: nil)
            )
        }
        do {
            let response: CmxIrohRegistrationResponse = try await sendUngated(
                path: "api/devices/iroh/register",
                method: "POST",
                body: request.including(discoveryScope: discoveryScope)
            )
            guard response.discovery != nil,
                  response.discoveryScope == discoveryScope,
                  response.discoveryScopeComplete == true,
                  response.discoveryComplete != true else {
                throw CmxIrohTrustBrokerClientError.invalidResponse
            }
            return response
        } catch let error as CmxIrohTrustBrokerClientError
            where isUnsupportedRegistrationScope(error) {
            // Registration parsing happens before challenge consumption, so
            // retrying the identical signature without the optional field is
            // safe against older strict servers.
            return try await sendUngated(
                path: "api/devices/iroh/register",
                method: "POST",
                body: request.including(discoveryScope: nil)
            )
        }
    }

    private func syncConnectivityUngated(
        knownRevision: UInt64?
    ) async throws -> CmxConnectivitySyncResponse {
        if let discoveryScope {
            do {
                let response: CmxConnectivitySyncResponse = try await sendUngated(
                    path: "api/connectivity/v3/sync",
                    method: "POST",
                    body: ConnectivitySyncRequest(
                        protocolVersion: CmxConnectivitySyncResponse.scopedProtocolVersion,
                        knownRevision: knownRevision,
                        discoveryScope: discoveryScope
                    )
                )
                guard response.protocolVersion
                        == CmxConnectivitySyncResponse.scopedProtocolVersion,
                      response.discoveryScope == discoveryScope,
                      !response.changed
                        || response.snapshotScopeComplete == true else {
                    throw CmxIrohTrustBrokerClientError.invalidResponse
                }
                return response
            } catch let error as CmxIrohTrustBrokerClientError
                where isMissingScopedDiscoveryRoute(error) {
                // Continue with connectivity v2 below.
            }
        }
        return try await sendUngated(
            path: "api/connectivity/v2/sync",
            method: "POST",
            body: ConnectivitySyncRequest(
                protocolVersion: CmxConnectivitySyncResponse.protocolVersion,
                knownRevision: knownRevision,
                discoveryScope: nil
            )
        )
    }

    private func send<Response: Decodable & Sendable, Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        operation: CmxIrohBrokerOperation
    ) async throws -> Response {
        let encoded = try JSONEncoder().encode(body)
        return try await withBackpressure(operation: operation) {
            try await self.performRequest(path: path, method: method, body: encoded)
        }
    }

    private func sendWithoutBody<Response: Decodable & Sendable>(
        path: String,
        method: String,
        operation: CmxIrohBrokerOperation
    ) async throws -> Response {
        try await withBackpressure(operation: operation) {
            try await self.performRequest(path: path, method: method, body: nil)
        }
    }

    private func discoverAllPages() async throws -> CmxIrohDiscoveryResponse {
        for attempt in 0 ..< 3 {
            do {
                return try await discoverSnapshotAttempt()
            } catch is DiscoverySnapshotChanged {
                if attempt == 2 {
                    throw CmxIrohTrustBrokerClientError.invalidResponse
                }
                // Older brokers expose discovery as optimistic pages. Restart
                // immediately from page one when an account mutation makes
                // those pages disagree. The next request captures the newly
                // committed revision, so a timing delay would add no safety.
                continue
            }
        }
        throw CmxIrohTrustBrokerClientError.invalidResponse
    }

    private func discoverSnapshotAttempt() async throws -> CmxIrohDiscoveryResponse {
        var bindings: [CmxIrohBrokerBinding] = []
        var bindingIDs: Set<String> = []
        var seenCursors: Set<String> = []
        var cursor: String?
        var first: CmxIrohDiscoveryResponse?

        repeat {
            var queryItems = [
                URLQueryItem(
                    name: "page_size",
                    value: String(CmxIrohDiscoveryPage.bindingLimit)
                ),
            ]
            if let cursor {
                queryItems.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let page: CmxIrohDiscoveryPage
            do {
                page = try await performRequest(
                    path: "api/devices/iroh",
                    method: "GET",
                    body: nil,
                    queryItems: queryItems
                )
            } catch let error as CmxIrohTrustBrokerClientError
                where cursor != nil && Self.isStaleDiscoveryCursor(error) {
                throw DiscoverySnapshotChanged()
            }
            if let first {
                guard page.discovery.routeContractVersion == first.routeContractVersion,
                      page.discovery.revision == first.revision,
                      page.discovery.relayFleet == first.relayFleet,
                      page.discovery.lanRendezvous == first.lanRendezvous,
                      page.discovery.grantVerificationKeys
                        == first.grantVerificationKeys else {
                    throw DiscoverySnapshotChanged()
                }
            } else {
                first = page.discovery
            }
            for binding in page.discovery.bindings {
                guard bindingIDs.insert(binding.bindingID).inserted else {
                    throw CmxIrohTrustBrokerClientError.invalidResponse
                }
                bindings.append(binding)
            }
            if let nextCursor = page.nextCursor {
                guard seenCursors.insert(nextCursor).inserted else {
                    throw CmxIrohTrustBrokerClientError.invalidResponse
                }
            }
            cursor = page.nextCursor
        } while cursor != nil

        guard let first else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        return CmxIrohDiscoveryResponse(
            routeContractVersion: first.routeContractVersion,
            revision: first.revision,
            bindings: bindings,
            relayFleet: first.relayFleet,
            lanRendezvous: first.lanRendezvous,
            grantVerificationKeys: first.grantVerificationKeys
        )
    }

    private static func isStaleDiscoveryCursor(
        _ error: CmxIrohTrustBrokerClientError
    ) -> Bool {
        guard case let .rejected(statusCode, code) = error else { return false }
        return statusCode == 409 && code == "discovery_cursor_stale"
    }

    private func sendUngated<Response: Decodable & Sendable, Body: Encodable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> Response {
        try await performRequest(
            path: path,
            method: method,
            body: JSONEncoder().encode(body)
        )
    }

    private func withBackpressure<Result: Sendable>(
        operation: CmxIrohBrokerOperation,
        _ body: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        guard let backpressureGate else { return try await body() }
        return try await backpressureGate.perform(
            accountID: CmxIrohBrokerBackpressureGate.directClientScope,
            operation: operation,
            body
        )
    }

    private func refreshSessionTicket() async throws -> String? {
        guard let configuration = sessionConfiguration else { return nil }
        let now = Date()

        // Renew before opening a second session. The old ticket remains usable
        // while a transient network failure is retried, so an outage does not
        // turn every ordinary broker request into a Stack Auth request.
        if let current = sessionState,
           current.expiresAt.timeIntervalSince(now) > 5 {
            do {
                let (data, response) = try await performSessionHTTP(
                    path: "v1/iroh/session/renew",
                    method: "POST",
                    body: nil,
                    ticket: current.ticket,
                    credentials: nil
                )
                if response.statusCode == 404 || response.statusCode == 405 {
                    sessionUnsupported = true
                    return nil
                }
                if response.statusCode == 401 {
                    sessionState = nil
                } else if response.statusCode >= 500 || response.statusCode == 429 {
                    // The current ticket is still valid. Do not turn a
                    // transient Worker/DO outage into a Stack bootstrap storm.
                    sessionState?.nextRenewAttempt = now.addingTimeInterval(30)
                    return current.ticket
                } else {
                    guard (200 ... 299).contains(response.statusCode) else {
                        throw sessionHTTPError(data: data, response: response)
                    }
                    return try installSessionResponse(data, now: now)
                }
            } catch let error as CmxIrohTrustBrokerClientError {
                if current.expiresAt.timeIntervalSince(now) > 5,
                   error.isConnectivity {
                    sessionState?.nextRenewAttempt = now.addingTimeInterval(30)
                    return current.ticket
                }
                throw error
            }
        }

        let pair = try await sessionCredentialPair()
        guard let pair else {
            throw CmxIrohTrustBrokerClientError.missingAuthentication
        }
        let body = try JSONEncoder().encode(SessionBootstrapBody(
            deviceID: configuration.deviceID,
            appInstanceID: configuration.appInstanceID,
            clientNamespace: configuration.clientNamespace,
            tag: configuration.tag,
            platform: configuration.platform
        ))
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await performSessionHTTP(
                path: "v1/iroh/session",
                method: "POST",
                body: body,
                ticket: nil,
                credentials: pair
            )
        } catch let error as CmxIrohTrustBrokerClientError {
            throw error
        }
        if response.statusCode == 404 || response.statusCode == 405 {
            // A staging Vercel origin predating the Worker simply has no
            // session route. Mark it once and retain the old authenticated
            // transport until that origin is migrated.
            sessionUnsupported = true
            return nil
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw sessionHTTPError(data: data, response: response)
        }
        return try installSessionResponse(data, now: now)
    }

    private func sessionCredentialPair() async throws -> CmxIrohBrokerCredentials? {
        do {
            return try await tokenSource.credentialPair()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CmxIrohTrustBrokerClientError.connectivity(
                (error as? URLError).map(CmxIrohBrokerConnectivityCause.init)
            )
        }
    }

    private func installSessionResponse(_ data: Data, now: Date) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(CmxIrohISO8601Date.decode)
        guard let response = try? decoder.decode(SessionResponse.self, from: data),
              cmxIsSafeBrokerHeaderValue(response.ticket),
              response.sessionId.utf8.count <= 128,
              !response.accountId.isEmpty,
              response.expiresAt.timeIntervalSince(now) > 5,
              response.renewAfter < response.expiresAt,
              response.renewAfter > now.addingTimeInterval(-60) else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        sessionState = SessionState(
            ticket: response.ticket,
            sessionID: response.sessionId,
            accountID: response.accountId,
            expiresAt: response.expiresAt,
            renewAfter: response.renewAfter,
            nextRenewAttempt: response.renewAfter
        )
        return response.ticket
    }

    private func performSessionHTTP(
        path: String,
        method: String,
        body: Data?,
        ticket: String?,
        credentials: CmxIrohBrokerCredentials?
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try makeURL(path: path, queryItems: [])
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientNamespace, forHTTPHeaderField: "X-Cmux-App-Namespace")
        if let ticket {
            guard cmxIsSafeBrokerHeaderValue(ticket) else {
                throw CmxIrohTrustBrokerClientError.invalidAuthentication
            }
            request.setValue(ticket, forHTTPHeaderField: cmxIrohSessionTicketHeader)
        }
        if let credentials {
            guard cmxIsSafeBrokerHeaderValue(credentials.accessToken),
                  cmxIsSafeBrokerHeaderValue(credentials.refreshToken) else {
                throw CmxIrohTrustBrokerClientError.invalidAuthentication
            }
            request.setValue(
                "Bearer \(credentials.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue(
                credentials.refreshToken,
                forHTTPHeaderField: "X-Stack-Refresh-Token"
            )
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError where Self.isConnectivityFailure(error.code) {
            throw CmxIrohTrustBrokerClientError.connectivity(
                CmxIrohBrokerConnectivityCause(error)
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw CmxIrohTrustBrokerClientError.nonHTTPResponse
        }
        guard http.url == url else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        return (data, http)
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        let pathURL = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(
            url: pathURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        return url
    }

    private func sessionHTTPError(
        data: Data,
        response: HTTPURLResponse
    ) -> CmxIrohTrustBrokerClientError {
        let payload = try? JSONDecoder().decode(CmxIrohTrustBrokerError.self, from: data)
        let code = payload.map { value in
            value.source.map { "\(value.error):\($0.rawValue)" } ?? value.error
        }
        return .rejected(statusCode: response.statusCode, code: code)
    }

    private func performRequest<Response: Decodable & Sendable>(
        path: String,
        method: String,
        body: Data?,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        if sessionConfiguration != nil, !sessionUnsupported {
            if let ticket = try await ensureSessionTicket() {
                do {
                    return try await performAuthenticatedRequest(
                        path: path,
                        method: method,
                        body: body,
                        queryItems: queryItems,
                        authorization: .session(ticket)
                    )
                } catch let error as CmxIrohTrustBrokerClientError
                    where Self.isUnauthorizedRejection(error) {
                    // A revoked or expired ticket is repaired once. The
                    // server-side session epoch and the endpoint proof still
                    // gate the retried request; this is not a blind retry.
                    sessionState = nil
                    guard let replacement = try await ensureSessionTicket() else {
                        throw error
                    }
                    return try await performAuthenticatedRequest(
                        path: path,
                        method: method,
                        body: body,
                        queryItems: queryItems,
                        authorization: .session(replacement)
                    )
                }
            }
        }
        return try await performLegacyRequest(
            path: path,
            method: method,
            body: body,
            queryItems: queryItems
        )
    }

    private func performLegacyRequest<Response: Decodable & Sendable>(
        path: String,
        method: String,
        body: Data?,
        queryItems: [URLQueryItem]
    ) async throws -> Response {
        // Build the request from ONE credential snapshot. Reading access then
        // refresh through two independent calls lets a force refresh land
        // between them and pair a stale access token with a rotated refresh
        // token, which the broker rejects.
        let capturedPair: CmxIrohBrokerCredentials?
        do {
            capturedPair = try await tokenSource.credentialPair()
        } catch is CancellationError {
            // A cancelled caller must observe cancellation, not a retryable
            // network failure: classifying it connectivity would let retry
            // and cached-policy fallbacks keep working on a cancelled task.
            throw CancellationError()
        } catch {
            // The source could not read a coherent pair right now (token store
            // mid-transition, re-mint in flight or offline). That is transient
            // and indistinguishable from an unreachable broker for every
            // caller policy (retry, cached-policy fallback, verified-policy
            // preservation), so classify it as connectivity, not as a
            // definitive authentication failure. A URL-loading failure from
            // the source's own refresh call keeps its code for attribution.
            throw CmxIrohTrustBrokerClientError.connectivity(
                (error as? URLError).map(CmxIrohBrokerConnectivityCause.init)
            )
        }
        guard let pair = capturedPair else {
            throw CmxIrohTrustBrokerClientError.missingAuthentication
        }
        do {
            return try await performAuthenticatedRequest(
                path: path,
                method: method,
                body: body,
                queryItems: queryItems,
                authorization: .stack(pair)
            )
        } catch let error as CmxIrohTrustBrokerClientError
            where Self.isUnauthorizedRejection(error) {
            // A pair that was coherent at capture can be rejected when another
            // lane rotated the session before the server validated it. Recover
            // ONCE with a pair minted after the rejection; a second rejection
            // is authoritative and propagates.
            let recovered: CmxIrohBrokerCredentials?
            do {
                recovered = try await tokenSource.recoveredCredentialPair(pair)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CmxIrohTrustBrokerClientError.connectivity(
                    (error as? URLError).map(CmxIrohBrokerConnectivityCause.init)
                )
            }
            guard let recovered else { throw error }
            return try await performAuthenticatedRequest(
                path: path,
                method: method,
                body: body,
                queryItems: queryItems,
                authorization: .stack(recovered)
            )
        }
    }

    private static func isUnauthorizedRejection(
        _ error: CmxIrohTrustBrokerClientError
    ) -> Bool {
        guard case let .rejected(statusCode, _) = error else { return false }
        return statusCode == 401
    }

    private func performAuthenticatedRequest<Response: Decodable & Sendable>(
        path: String,
        method: String,
        body: Data?,
        queryItems: [URLQueryItem],
        authorization: RequestAuthorization
    ) async throws -> Response {
        let url = try makeURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        switch authorization {
        case let .stack(credentials):
            guard cmxIsSafeBrokerHeaderValue(credentials.accessToken),
                  cmxIsSafeBrokerHeaderValue(credentials.refreshToken) else {
                throw CmxIrohTrustBrokerClientError.invalidAuthentication
            }
            request.setValue(
                "Bearer \(credentials.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue(
                credentials.refreshToken,
                forHTTPHeaderField: "X-Stack-Refresh-Token"
            )
        case let .session(ticket):
            guard cmxIsSafeBrokerHeaderValue(ticket) else {
                throw CmxIrohTrustBrokerClientError.invalidAuthentication
            }
            request.setValue(ticket, forHTTPHeaderField: cmxIrohSessionTicketHeader)
        }
        request.setValue(clientNamespace, forHTTPHeaderField: "X-Cmux-App-Namespace")
        if let bindingAuthorization,
           path != "api/devices/iroh/challenge",
           path != "api/devices/iroh/register" {
            let timestamp = Int64(Date().timeIntervalSince1970)
            let signature = try bindingAuthorization.signer.signBrokerRequest(
                bindingID: bindingAuthorization.bindingID,
                method: method,
                path: path,
                timestamp: timestamp,
                body: body ?? Data()
            )
            request.setValue(
                bindingAuthorization.bindingID,
                forHTTPHeaderField: "X-Cmux-Iroh-Binding-ID"
            )
            request.setValue(
                String(timestamp),
                forHTTPHeaderField: "X-Cmux-Iroh-Request-Time"
            )
            request.setValue(
                signature,
                forHTTPHeaderField: "X-Cmux-Iroh-Request-Signature"
            )
        }
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
            throw CmxIrohTrustBrokerClientError.connectivity(
                CmxIrohBrokerConnectivityCause(error)
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw CmxIrohTrustBrokerClientError.nonHTTPResponse
        }
        guard http.url == url else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(CmxIrohTrustBrokerError.self, from: data)
            let code = body.map { payload in
                payload.source.map { "\(payload.error):\($0.rawValue)" } ?? payload.error
            }
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

    private static func retryAfterSeconds(_ value: String?) -> Int? {
        guard let value,
              !value.isEmpty,
              value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let seconds = Int(value),
              (1 ... CmxIrohBrokerCooldown.maximumRetryAfterSeconds).contains(seconds),
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
