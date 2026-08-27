public import CMUXMobileCore
public import Foundation

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

public actor CmxIrohTrustBrokerClient: CmxIrohRelayPolicyServing {
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
    private struct PublishEndpointRecordRequest: Encodable {
        let bindingId: String
        let record: String
    }
    private struct PublishEndpointRecordResponse: Decodable, Sendable {
        let published: Bool
    }
    private struct RelayPolicyBootstrapResponse: Decodable, Sendable {
        let policy: String
        let preference: CmxIrohAccountRelayConfiguration
        let preferenceRevision: Int64
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
    private struct BrokerError: Decodable { let error: String }

    private let baseURL: URL
    private let tokenSource: CmxIrohBrokerTokenSource
    private let transport: any CmxIrohHTTPTransport
    private let requestTimeout: TimeInterval
    private let backpressureGate: CmxIrohBrokerBackpressureGate?
    private let clientNamespace: String
    private var bindingAuthorization: CmxIrohBindingRequestAuthorization?
    private let discoveryScope: CmxConnectivityDiscoveryScope?

    /// Creates a client that rejects cleartext non-loopback API origins.
    public init(
        baseURL: URL,
        tokenSource: CmxIrohBrokerTokenSource,
        clientNamespace: String,
        bindingAuthorization: CmxIrohBindingRequestAuthorization? = nil,
        discoveryScope: CmxConnectivityDiscoveryScope? = nil,
        requestTimeout: TimeInterval = 10,
        backpressureMode: CmxIrohBrokerBackpressureMode = .automatic
    ) throws {
        try self.init(
            baseURL: baseURL,
            tokenSource: tokenSource,
            clientNamespace: clientNamespace,
            bindingAuthorization: bindingAuthorization,
            discoveryScope: discoveryScope,
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
        transport: any CmxIrohHTTPTransport,
        requestTimeout: TimeInterval = 10,
        backpressureMode: CmxIrohBrokerBackpressureMode = .automatic
    ) throws {
        guard Self.isAllowedBaseURL(baseURL),
              cmxIsSafeClientNamespace(clientNamespace),
              bindingAuthorization?.clientNamespace == nil
                || bindingAuthorization?.clientNamespace == clientNamespace,
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

    /// Fetches the signed, server-driven relay policy for the account.
    public func fetchRelayPolicy() async throws -> CmxIrohRelayPolicyResponse {
        let response: RelayPolicyBootstrapResponse = try await sendWithoutBody(
            path: "api/relay/policy",
            method: "GET",
            operation: .relayCredential
        )
        do {
            return try CmxIrohRelayPolicyResponse(
                policy: response.policy,
                preference: response.preference,
                preferenceRevision: response.preferenceRevision
            )
        } catch {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
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
    /// Uploads this endpoint's own signed pkarr record as an opaque blob
    /// attached to its active binding. The broker checks write admission
    /// (binding-request proof, size, key match); readers re-verify the
    /// record signature themselves, so broker storage stays untrusted.
    public func publishEndpointRecord(bindingID: String, record: Data) async throws {
        guard !record.isEmpty,
              record.count <= CmxIrohBrokerBinding.maximumEndpointRecordByteCount else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        let response: PublishEndpointRecordResponse = try await send(
            path: "api/devices/iroh/endpoint-record",
            method: "POST",
            body: PublishEndpointRecordRequest(
                bindingId: bindingID,
                record: record.base64EncodedString()
            ),
            operation: .endpointRecord
        )
        guard response.published else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
    }

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

    private func performRequest<Response: Decodable & Sendable>(
        path: String,
        method: String,
        body: Data?,
        queryItems: [URLQueryItem] = []
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
            // definitive authentication failure.
            throw CmxIrohTrustBrokerClientError.connectivity
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
                credentials: pair
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
                throw CmxIrohTrustBrokerClientError.connectivity
            }
            guard let recovered else { throw error }
            return try await performAuthenticatedRequest(
                path: path,
                method: method,
                body: body,
                queryItems: queryItems,
                credentials: recovered
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
        credentials: CmxIrohBrokerCredentials
    ) async throws -> Response {
        let accessToken = credentials.accessToken
        let refreshToken = credentials.refreshToken
        guard cmxIsSafeBrokerHeaderValue(accessToken),
              cmxIsSafeBrokerHeaderValue(refreshToken) else {
            throw CmxIrohTrustBrokerClientError.invalidAuthentication
        }
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
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        // A debug-only deployment-protection bypass lets a tagged test build
        // reach a protected broker preview; nil in release builds.
        if let bypass = CmxIrohDebugBrokerBypassHeader.activeValue() {
            request.setValue(
                bypass,
                forHTTPHeaderField: CmxIrohDebugBrokerBypassHeader.headerField
            )
        }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
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
