public import CMUXMobileCore
public import CmuxIrohTransport
public import Foundation

public enum IrxBrokerServiceError: Error, Sendable {
    case notRegistered
    case invalidIdentity
    case noCredentialsIssued
    case unknownRelayURL(String)
}

/// Persisted registration receipt: the full binding tuple, so the host can
/// build its exact acceptor identity for grant verification with the backend
/// unreachable.
public struct IrxBindingSnapshot: Codable, Equatable, Sendable {
    public var bindingID: String
    public var deviceID: String
    public var tag: String
    public var endpointIDHex: String
    public var identityGeneration: Int
    public var registeredAt: Date

    public init(
        bindingID: String,
        deviceID: String,
        tag: String,
        endpointIDHex: String,
        identityGeneration: Int,
        registeredAt: Date
    ) {
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.tag = tag
        self.endpointIDHex = endpointIDHex
        self.identityGeneration = identityGeneration
        self.registeredAt = registeredAt
    }
}

/// Persisted grant-verification material and peer directory from the last
/// authenticated discovery. Admission verifies OFFLINE against this; a stale
/// copy is refreshed opportunistically in the background, never on the
/// admission or dial path.
public struct IrxTrustSnapshot: Codable, Equatable, Sendable {
    public var verificationKeys: CmxIrohGrantVerificationKeySet
    public var relayFleet: [String]
    public var fetchedAt: Date

    public init(
        verificationKeys: CmxIrohGrantVerificationKeySet,
        relayFleet: [String],
        fetchedAt: Date
    ) {
        self.verificationKeys = verificationKeys
        self.relayFleet = relayFleet
        self.fetchedAt = fetchedAt
    }
}

/// Persisted pair grant for one acceptor binding.
public struct IrxGrantSnapshot: Codable, Equatable, Sendable {
    public var acceptorBindingID: String
    public var grantJWS: String
    public var expiresAt: Date

    public init(acceptorBindingID: String, grantJWS: String, expiresAt: Date) {
        self.acceptorBindingID = acceptorBindingID
        self.grantJWS = grantJWS
        self.expiresAt = expiresAt
    }

    /// Grants live 7 days; treat the last 24h as stale so renewal always has
    /// days of margin and can never cause a connect-time flurry.
    public func isFresh(at now: Date) -> Bool {
        expiresAt.timeIntervalSince(now) > 24 * 3600
    }
}

/// Orchestrates the existing trust-broker HTTP client (reused as pure wire
/// plumbing) under irx's temporal rules: every result is cached to disk, the
/// dial path never waits on the backend, and every call is journaled.
public actor IrxBrokerService {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var clientNamespace: String
        public var tag: String
        public var platform: CmxIrohPlatform
        public var displayName: String?
        public var cacheDirectory: URL
        /// Rotates only when the endpoint identity rotates (legacy-adopted
        /// identities carry their existing generation).
        public var identityGeneration: Int

        public init(
            baseURL: URL,
            clientNamespace: String,
            tag: String,
            platform: CmxIrohPlatform,
            displayName: String?,
            cacheDirectory: URL,
            identityGeneration: Int = 1
        ) {
            self.baseURL = baseURL
            self.clientNamespace = clientNamespace
            self.tag = tag
            self.platform = platform
            self.displayName = displayName
            self.cacheDirectory = cacheDirectory
            self.identityGeneration = identityGeneration
        }
    }

    private let configuration: Configuration
    private let identity: IrxIdentity
    private let journal: IrxJournal
    private let client: CmxIrohTrustBrokerClient
    private let bindingCache: IrxDiskCache<IrxBindingSnapshot>
    private let trustCache: IrxDiskCache<IrxTrustSnapshot>
    private let credentialCache: IrxDiskCache<IrxRelayCredentialSnapshot>
    private let grantCache: IrxDiskCache<[String: IrxGrantSnapshot]>
    private var registrationInFlight: Task<IrxBindingSnapshot, any Error>?
    private var lastHintRegistered: (url: String?, at: Date)?
    private var lastDiscovery: CmxIrohDiscoveryResponse?
    private var lastDiscoveryAt: Date?

    public init(
        configuration: Configuration,
        identity: IrxIdentity,
        accessTokenPair: @escaping @Sendable () async throws -> (access: String, refresh: String)?,
        journal: IrxJournal
    ) throws {
        self.configuration = configuration
        self.identity = identity
        self.journal = journal
        let tokenSource = CmxIrohBrokerTokenSource(credentialPair: {
            guard let pair = try await accessTokenPair() else { return nil }
            return CmxIrohBrokerCredentials(
                accessToken: pair.access,
                refreshToken: pair.refresh
            )
        })
        let dir = configuration.cacheDirectory
        bindingCache = IrxDiskCache(fileURL: dir.appendingPathComponent("binding.json"))
        // Warm launches skip register() for speed, but register() is what
        // arms per-request binding-proof signing; an unarmed client sends
        // proofless mints that the broker 403s (binding_request_proof_required)
        // - the 08-27 INTERNAL wedge. Reconstruct the authorization offline
        // from the cached binding and the identity key, so every request is
        // signed from the first call regardless of registration order.
        var retainedAuthorization: CmxIrohBindingRequestAuthorization?
        if let snapshot = bindingCache.load(),
            snapshot.endpointIDHex == identity.endpointIDHex,
            let secretKey = try? CmxIrohSecretKey(bytes: identity.privateKeyData),
            let material = try? CmxIrohIdentityMaterial(
                secretKey: secretKey, generation: configuration.identityGeneration),
            let endpointID = try? CmxIrohPeerIdentity(endpointID: identity.endpointIDHex)
        {
            retainedAuthorization = try? CmxIrohBindingRequestAuthorization(
                bindingID: snapshot.bindingID,
                clientNamespace: configuration.clientNamespace,
                identity: material,
                endpointID: endpointID
            )
        }
        client = try CmxIrohTrustBrokerClient(
            baseURL: configuration.baseURL,
            tokenSource: tokenSource,
            clientNamespace: configuration.clientNamespace,
            bindingAuthorization: retainedAuthorization
        )
        trustCache = IrxDiskCache(fileURL: dir.appendingPathComponent("trust.json"))
        credentialCache = IrxDiskCache(fileURL: dir.appendingPathComponent("relay-credentials.json"))
        grantCache = IrxDiskCache(fileURL: dir.appendingPathComponent("grants.json"))
    }

    /// The underlying trust-broker client, exposed for the legacy-dialect
    /// admission registry (online revalidation parity for old phones).
    public nonisolated var hostBrokerClient: CmxIrohTrustBrokerClient { client }

    // MARK: - Registration

    public func cachedBinding() -> IrxBindingSnapshot? {
        guard let snapshot = bindingCache.load(),
            snapshot.endpointIDHex == identity.endpointIDHex
        else { return nil }
        return snapshot
    }

    /// Hint refresh with churn control: every registration write bumps the
    /// account route revision and fans an invalidation push to EVERY device
    /// on the account (legacy stacks re-dial pooled sessions on each one), so
    /// re-register only when the relay URL changed or the 30-minute hint has
    /// burned half its window. Same never-lapses guarantee, ~5x fewer writes.
    public func registerHintIfNeeded(
        pairingEnabled: Bool,
        relayURLHint: String?
    ) async throws {
        if let last = lastHintRegistered,
            last.url == relayURLHint,
            Date().timeIntervalSince(last.at) < 15 * 60
        {
            return
        }
        _ = try await register(pairingEnabled: pairingEnabled, relayURLHint: relayURLHint)
    }

    /// Registers (or refreshes) this endpoint's binding. Single-flight;
    /// pathHints advertise the relay URL so peers can dial relay-first.
    public func register(
        pairingEnabled: Bool,
        relayURLHint: String?,
        directPorts: CmxIrohDirectPorts? = nil
    ) async throws -> IrxBindingSnapshot {
        if let registrationInFlight {
            return try await registrationInFlight.value
        }
        let task = Task<IrxBindingSnapshot, any Error> {
            try await self.registerOnce(
                pairingEnabled: pairingEnabled,
                relayURLHint: relayURLHint,
                directPorts: directPorts
            )
        }
        registrationInFlight = task
        defer { registrationInFlight = nil }
        return try await task.value
    }

    private func registerOnce(
        pairingEnabled: Bool,
        relayURLHint: String?,
        directPorts: CmxIrohDirectPorts?
    ) async throws -> IrxBindingSnapshot {
        let startedAt = DispatchTime.now()
        var hints: [CmxIrohPathHint] = []
        let now = Date()
        if let relayURLHint {
            if let hint = try? CmxIrohPathHint(
                kind: .relayURL,
                value: relayURLHint,
                source: .native,
                privacyScope: .publicInternet,
                observedAt: now,
                expiresAt: now.addingTimeInterval(30 * 60)
            ) {
                hints.append(hint)
            }
        }
        let secretKey = try CmxIrohSecretKey(bytes: identity.privateKeyData)
        let material = try CmxIrohIdentityMaterial(
            secretKey: secretKey, generation: configuration.identityGeneration)
        let payload = try CmxIrohRegistrationPayload(
            deviceID: identity.deviceID,
            appInstanceID: identity.appInstanceID,
            clientNamespace: configuration.clientNamespace,
            tag: configuration.tag,
            platform: configuration.platform,
            displayName: configuration.displayName,
            endpointID: identity.endpointIDHex,
            identityGeneration: configuration.identityGeneration,
            pairingEnabled: pairingEnabled,
            capabilities: ["cmux.irx.v1"],
            pathHints: hints,
            directPorts: directPorts
        )
        let signer = try CmxIrohRegistrationSigner(
            identity: material,
            endpointID: identity.endpointIDHex
        )
        let prepared = try signer.prepare(payload: payload)
        let response = try await client.register(prepared: prepared, signer: signer)
        let snapshot = IrxBindingSnapshot(
            bindingID: response.binding.bindingID,
            deviceID: response.binding.deviceID,
            tag: response.binding.tag,
            endpointIDHex: identity.endpointIDHex,
            identityGeneration: response.binding.identityGeneration,
            registeredAt: Date()
        )
        bindingCache.save(snapshot)
        lastHintRegistered = (relayURLHint, Date())
        let elapsedMs =
            (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        journal.record(
            "broker", "registered",
            [
                "binding": snapshot.bindingID,
                "tag": configuration.tag,
                "pairing_enabled": String(pairingEnabled),
                "elapsed_ms": String(elapsedMs),
            ]
        )
        return snapshot
    }

    // MARK: - Discovery / trust material

    public func cachedTrust() -> IrxTrustSnapshot? {
        trustCache.load()
    }

    /// Fresh-enough discovery, from memory or the wire. Never called on the
    /// admission path; admission uses `cachedTrust()`.
    public func discover(maximumAge: TimeInterval = 30) async throws -> CmxIrohDiscoveryResponse {
        if let lastDiscovery, let lastDiscoveryAt,
            Date().timeIntervalSince(lastDiscoveryAt) < maximumAge
        {
            return lastDiscovery
        }
        let startedAt = DispatchTime.now()
        let response = try await client.discover()
        lastDiscovery = response
        lastDiscoveryAt = Date()
        trustCache.save(
            IrxTrustSnapshot(
                verificationKeys: response.grantVerificationKeys,
                relayFleet: response.relayFleet,
                fetchedAt: Date()
            )
        )
        let elapsedMs =
            (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        journal.record(
            "broker", "discovered",
            [
                "bindings": String(response.bindings.count),
                "revision": response.revision.map(String.init) ?? "-",
                "elapsed_ms": String(elapsedMs),
            ]
        )
        return response
    }

    // MARK: - Relay credentials

    public func cachedRelayCredentials() -> [IrxRelayCredential] {
        guard let snapshot = credentialCache.load(),
            snapshot.endpointIDHex == identity.endpointIDHex
        else { return [] }
        return snapshot.usable(at: Date())
    }

    /// A broker proof rejection means the retained binding or its signing
    /// authorization is stale server-side. Drop the cached binding so the
    /// next provisioning attempt takes the full register() path (which
    /// re-arms signing on this client) instead of retrying into the same
    /// rejection forever.
    private func invalidateBindingOnProofRejection(_ error: any Error) {
        guard case let .rejected(statusCode, code)? = error as? CmxIrohTrustBrokerClientError,
            statusCode == 403,
            code == "binding_request_proof_required" || code == "invalid_binding_request_proof"
        else { return }
        bindingCache.clear()
        journal.record(
            "broker", "binding-invalidated-on-proof-rejection",
            ["code": code ?? "-"]
        )
    }

    /// Mints fresh endpoint-bound relay credentials. Only relay URLs present
    /// in the authenticated discovery fleet are accepted, so a corrupted
    /// credential response can never point the endpoint at a foreign relay.
    public func mintRelayCredentials() async throws -> [IrxRelayCredential] {
        let startedAt = DispatchTime.now()
        let endpointID = try CmxIrohPeerIdentity(endpointID: identity.endpointIDHex)
        let bootstrap: CmxIrohRelayBootstrapResponse
        do {
            bootstrap = try await client.issueRelayBootstrap(endpointID: endpointID)
        } catch {
            invalidateBindingOnProofRejection(error)
            throw error
        }
        guard let tokenResponse = bootstrap.relayToken else {
            journal.record("broker", "relay-mint-empty")
            throw IrxBrokerServiceError.noCredentialsIssued
        }
        let allowedFleet = Set(
            (trustCache.load()?.relayFleet ?? []) + tokenResponse.relayFleet
        )
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var minted: [IrxRelayCredential] = []
        for credential in tokenResponse.credentials {
            guard allowedFleet.contains(credential.relayURL) else {
                throw IrxBrokerServiceError.unknownRelayURL(credential.relayURL)
            }
            guard
                let expiresAt = iso.date(from: credential.expiresAt)
                    ?? fractional.date(from: credential.expiresAt),
                let refreshAfter = iso.date(from: credential.refreshAfter)
                    ?? fractional.date(from: credential.refreshAfter)
            else { continue }
            minted.append(
                IrxRelayCredential(
                    relayURL: credential.relayURL,
                    token: credential.token,
                    expiresAt: expiresAt,
                    refreshAfter: refreshAfter
                )
            )
        }
        guard !minted.isEmpty else {
            throw IrxBrokerServiceError.noCredentialsIssued
        }
        credentialCache.save(
            IrxRelayCredentialSnapshot(
                credentials: minted,
                mintedAt: Date(),
                endpointIDHex: identity.endpointIDHex
            ))
        let elapsedMs =
            (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        journal.record(
            "broker", "relay-minted",
            [
                "relays": minted.map(\.relayURL).joined(separator: ","),
                "expires_at": iso.string(from: minted[0].expiresAt),
                "refresh_after": iso.string(from: minted[0].refreshAfter),
                "elapsed_ms": String(elapsedMs),
            ]
        )
        return minted
    }

    // MARK: - Pair grants (keyed by the acceptor's endpoint, what routes carry)

    public func cachedGrant(
        acceptorEndpointIDHex: String,
        now: Date = Date()
    ) -> IrxGrantSnapshot? {
        guard let grants = grantCache.load(),
            let snapshot = grants[acceptorEndpointIDHex],
            snapshot.isFresh(at: now)
        else { return nil }
        return snapshot
    }

    /// Drops a grant the host just refused, so the next dial re-mints
    /// instead of re-presenting stale cache.
    public func dropGrant(acceptorEndpointIDHex: String) {
        var grants = grantCache.load() ?? [:]
        guard grants.removeValue(forKey: acceptorEndpointIDHex) != nil else { return }
        grantCache.save(grants)
        journal.record("broker", "grant-dropped", ["acceptor": acceptorEndpointIDHex])
    }

    /// Mints (and caches) a pair grant naming this device as initiator.
    public func issuePairGrant(
        acceptorBindingID: String,
        acceptorEndpointIDHex: String
    ) async throws -> IrxGrantSnapshot {
        guard let binding = cachedBinding() else {
            throw IrxBrokerServiceError.notRegistered
        }
        let response: CmxIrohPairGrantResponse
        do {
            response = try await client.issuePairGrant(
                initiatorBindingID: binding.bindingID,
                acceptorBindingID: acceptorBindingID
            )
        } catch {
            invalidateBindingOnProofRejection(error)
            throw error
        }
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt =
            iso.date(from: response.expiresAt)
            ?? fractional.date(from: response.expiresAt)
            ?? Date().addingTimeInterval(7 * 24 * 3600)
        let snapshot = IrxGrantSnapshot(
            acceptorBindingID: acceptorBindingID,
            grantJWS: response.grant,
            expiresAt: expiresAt
        )
        var grants = grantCache.load() ?? [:]
        grants[acceptorEndpointIDHex] = snapshot
        grantCache.save(grants)
        journal.record(
            "broker", "grant-issued",
            [
                "acceptor": acceptorBindingID,
                "expires_at": iso.string(from: expiresAt),
            ]
        )
        return snapshot
    }
}
