public import CMUXMobileCore
public import Foundation

/// Authenticated client for endpoint registration, discovery, grants, and
/// relay tokens.
///
/// The paths, methods, headers, and bodies are byte-for-byte the previous
/// transport's; the server does not change in this program. Simplifications
/// relative to the old client: no built-in backpressure gate (rate-limit
/// floors live in the account-scoped cooldown ledger above the connection
/// lifecycle), and no legacy-server fallback retries (scoped registration and
/// connectivity v3 are assumed supported, as they are by the fixed server).
public actor PeerTrustBrokerClient {
    struct DiscoverySnapshotChanged: Error {}

    private struct BindingRequestBody: Encodable { let bindingId: String }
    private struct EndpointRequestBody: Encodable { let endpointId: String }
    private struct PairGrantRequestBody: Encodable {
        let initiatorBindingId: String
        let acceptorBindingId: String
    }

    let baseURL: URL
    let tokenProvider: PeerBrokerTokenProvider
    let transport: any PeerBrokerHTTPTransporting
    let requestTimeout: TimeInterval
    let clientNamespace: String
    let discoveryScope: PeerDiscoveryScope?
    var bindingAuthorization: PeerBindingRequestAuthorization?

    /// Creates a client that rejects cleartext non-loopback API origins.
    public init(
        baseURL: URL,
        tokenProvider: PeerBrokerTokenProvider,
        clientNamespace: String,
        bindingAuthorization: PeerBindingRequestAuthorization? = nil,
        discoveryScope: PeerDiscoveryScope? = nil,
        transport: any PeerBrokerHTTPTransporting = PeerBrokerURLSessionTransport(),
        requestTimeout: TimeInterval = 10
    ) throws {
        guard Self.isAllowedBaseURL(baseURL),
              PeerBrokerWire.isSafeClientNamespace(clientNamespace),
              bindingAuthorization?.clientNamespace == nil
                || bindingAuthorization?.clientNamespace == clientNamespace,
              requestTimeout > 0 else {
            throw PeerBrokerError.protocolError
        }
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.clientNamespace = clientNamespace
        self.bindingAuthorization = bindingAuthorization
        self.discoveryScope = discoveryScope
    }

    /// Reports whether this client retains a signed binding request proof.
    public func hasBindingAuthorization() -> Bool {
        bindingAuthorization != nil
    }

    /// Returns the binding ID represented by the retained request proof.
    public func bindingAuthorizationID() -> String? {
        bindingAuthorization?.bindingID
    }

    /// POST `api/devices/iroh/challenge`.
    public func challenge(
        _ request: PeerBrokerChallengeRequest
    ) async throws -> PeerBrokerChallengeResponse {
        try await send(path: "api/devices/iroh/challenge", method: "POST", body: request)
    }

    /// POST `api/devices/iroh/register`.
    public func register(
        _ request: PeerBrokerRegisterRequest
    ) async throws -> PeerBrokerRegistrationResponse {
        guard let discoveryScope else {
            return try await send(
                path: "api/devices/iroh/register",
                method: "POST",
                body: request.including(discoveryScope: nil)
            )
        }
        let response: PeerBrokerRegistrationResponse = try await send(
            path: "api/devices/iroh/register",
            method: "POST",
            body: request.including(discoveryScope: discoveryScope)
        )
        guard response.discovery != nil,
              response.discoveryScope == discoveryScope,
              response.discoveryScopeComplete == true,
              response.discoveryComplete != true else {
            throw PeerBrokerError.protocolError
        }
        return response
    }

    /// Runs the challenge and signed registration legs without regenerating
    /// payload bytes, then retains the binding proof for subsequent requests.
    public func register(
        prepared: PeerPreparedRegistration,
        signer: PeerRegistrationSigner
    ) async throws -> PeerBrokerRegistrationResponse {
        let challenge = try await challenge(prepared.challengeRequest)
        let request = try signer.sign(prepared: prepared, challenge: challenge)
        let response = try await register(request)
        bindingAuthorization = PeerBindingRequestAuthorization(
            bindingID: response.binding.bindingID,
            clientNamespace: clientNamespace,
            signer: signer
        )
        return response
    }

    /// GET `api/devices/iroh` (bounded pages assembled into one snapshot).
    public func discover() async throws -> PeerBrokerDiscoverySnapshot {
        for attempt in 0 ..< 3 {
            do {
                return try await discoverSnapshotAttempt()
            } catch is DiscoverySnapshotChanged {
                if attempt == 2 {
                    throw PeerBrokerError.protocolError
                }
                // The broker exposes discovery as optimistic pages. Restart
                // immediately from page one when an account mutation makes
                // those pages disagree; the next request captures the newly
                // committed revision.
                continue
            }
        }
        throw PeerBrokerError.protocolError
    }

    /// POST `api/connectivity/v3/sync` (scoped) or `api/connectivity/v2/sync`.
    public func connectivitySync(
        knownRevision: UInt64?
    ) async throws -> PeerConnectivitySyncResponse {
        guard let discoveryScope else {
            return try await send(
                path: "api/connectivity/v2/sync",
                method: "POST",
                body: PeerConnectivitySyncRequest(
                    protocolVersion: PeerConnectivitySyncResponse.protocolVersion,
                    knownRevision: knownRevision,
                    discoveryScope: nil
                )
            )
        }
        let response: PeerConnectivitySyncResponse = try await send(
            path: "api/connectivity/v3/sync",
            method: "POST",
            body: PeerConnectivitySyncRequest(
                protocolVersion: PeerConnectivitySyncResponse.scopedProtocolVersion,
                knownRevision: knownRevision,
                discoveryScope: discoveryScope
            )
        )
        guard response.protocolVersion
                == PeerConnectivitySyncResponse.scopedProtocolVersion,
              response.discoveryScope == discoveryScope,
              !response.changed || response.snapshotScopeComplete == true else {
            throw PeerBrokerError.protocolError
        }
        return response
    }

    /// POST `api/devices/iroh/pair-grants`.
    public func issuePairGrant(
        initiatorBindingID: String,
        acceptorBindingID: String
    ) async throws -> PeerPairGrantResponse {
        try await send(
            path: "api/devices/iroh/pair-grants",
            method: "POST",
            body: PairGrantRequestBody(
                initiatorBindingId: initiatorBindingID,
                acceptorBindingId: acceptorBindingID
            )
        )
    }

    /// POST `api/devices/iroh/endpoint-attestations`.
    public func issueEndpointAttestation(
        bindingID: String
    ) async throws -> PeerEndpointAttestationResponse {
        try await send(
            path: "api/devices/iroh/endpoint-attestations",
            method: "POST",
            body: BindingRequestBody(bindingId: bindingID)
        )
    }

    /// POST `api/relay/token`.
    public func relayToken(
        endpointID: CmxIrohPeerIdentity
    ) async throws -> PeerBrokerRelayTokenResponse {
        let response: PeerBrokerRelayAccessResponse = try await send(
            path: "api/relay/token",
            method: "POST",
            body: EndpointRequestBody(endpointId: endpointID.endpointID)
        )
        return try response.tokenResponse(endpointID: endpointID)
    }

    /// DELETE `api/devices/iroh`.
    public func revokeBinding(
        _ bindingID: String,
        intent: PeerBindingRevocationIntent = .own
    ) async throws {
        let response: PeerBrokerRevokeResponse = try await send(
            path: "api/devices/iroh",
            method: "DELETE",
            body: PeerBrokerRevokeRequest(bindingID: bindingID, intent: intent)
        )
        guard response.revoked, response.lanRendezvousRotated else {
            throw PeerBrokerError.protocolError
        }
    }

    private func discoverSnapshotAttempt() async throws -> PeerBrokerDiscoverySnapshot {
        var bindings: [PeerBrokerBinding] = []
        var bindingIDs: Set<String> = []
        var seenCursors: Set<String> = []
        var cursor: String?
        var first: PeerBrokerDiscoverySnapshot?

        repeat {
            var queryItems = [
                URLQueryItem(
                    name: "page_size",
                    value: String(PeerBrokerDiscoveryPage.bindingLimit)
                ),
            ]
            if let cursor {
                queryItems.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let page: PeerBrokerDiscoveryPage
            do {
                page = try await performRequest(
                    path: "api/devices/iroh",
                    method: "GET",
                    body: nil,
                    queryItems: queryItems
                )
            } catch let error as PeerBrokerError
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
                    throw PeerBrokerError.protocolError
                }
                bindings.append(binding)
            }
            if let nextCursor = page.nextCursor {
                guard seenCursors.insert(nextCursor).inserted else {
                    throw PeerBrokerError.protocolError
                }
            }
            cursor = page.nextCursor
        } while cursor != nil

        guard let first else {
            throw PeerBrokerError.protocolError
        }
        return PeerBrokerDiscoverySnapshot(
            routeContractVersion: first.routeContractVersion,
            revision: first.revision,
            bindings: bindings,
            relayFleet: first.relayFleet,
            lanRendezvous: first.lanRendezvous,
            grantVerificationKeys: first.grantVerificationKeys
        )
    }

    private static func isStaleDiscoveryCursor(_ error: PeerBrokerError) -> Bool {
        guard case let .denied(statusCode, code) = error else { return false }
        return statusCode == 409 && code == "discovery_cursor_stale"
    }

    private func send<Response: Decodable & Sendable, Body: Encodable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> Response {
        try await performRequest(
            path: path,
            method: method,
            body: JSONEncoder().encode(body),
            queryItems: []
        )
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
}
