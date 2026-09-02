public import CMUXMobileCore
public import CmuxIrohTransport
public import Foundation

public enum IrxBrokerServiceError: Error, Sendable {
    case notRegistered
    case invalidIdentity
    case noCredentialsIssued
    case unknownRelayURL(String)
    case deactivated
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
        /// The signed-in account. With it, Release builds keep the broker
        /// caches in the Keychain (`com.cmuxterm.irx.cache.v1`, account
        /// `<kind>|<accountID>|<backendHost>`). Scoped Release caches never
        /// import unscoped legacy JSON files because those snapshots have no
        /// account/backend owner; a fresh authenticated registration or mint
        /// repopulates the scoped item. Without a scope (and in every DEBUG
        /// build), the files remain the temporary store.
        public var accountID: String?
        /// The app's Keychain access group (iOS); nil on macOS.
        public var keychainAccessGroup: String?

        public init(
            baseURL: URL,
            clientNamespace: String,
            tag: String,
            platform: CmxIrohPlatform,
            displayName: String?,
            cacheDirectory: URL,
            identityGeneration: Int = 1,
            accountID: String? = nil,
            keychainAccessGroup: String? = nil
        ) {
            self.baseURL = baseURL
            self.clientNamespace = clientNamespace
            self.tag = tag
            self.platform = platform
            self.displayName = displayName
            self.cacheDirectory = cacheDirectory
            self.identityGeneration = identityGeneration
            self.accountID = accountID
            self.keychainAccessGroup = keychainAccessGroup
        }

        var cacheScope: IrxBrokerCacheScope? {
            guard let accountID, let backendHost = baseURL.host else { return nil }
            return IrxBrokerCacheScope(
                accountID: accountID,
                backendHost: backendHost,
                keychainAccessGroup: keychainAccessGroup
            )
        }
    }

    private let configuration: Configuration
    private let identity: IrxIdentity
    private let journal: IrxJournal
    private let client: CmxIrohTrustBrokerClient
    private let bindingCache: any IrxJSONCache<IrxBindingSnapshot>
    private let trustCache: any IrxJSONCache<IrxTrustSnapshot>
    private let credentialCache: any IrxJSONCache<IrxRelayCredentialSnapshot>
    private let grantCache: any IrxJSONCache<[String: IrxGrantSnapshot]>
    private var registrationInFlight: Task<IrxBindingSnapshot, any Error>?
    private var lastHintRegistered: (url: String?, at: Date)?
    private var lastDiscovery: CmxIrohDiscoveryResponse?
    private var lastDiscoveryAt: Date?
    /// Monotonic lifecycle fence. URLSession work can outlive task
    /// cancellation, so every async operation captures this value and proves
    /// it is still current before publishing a cache result.
    private var lifecycleEpoch: UInt64 = 0
    private var deactivated = false

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
        let scope = configuration.cacheScope
        bindingCache = IrxBrokerCacheFactory.make(
            kind: "binding",
            fileURL: dir.appendingPathComponent("binding.json"),
            scope: scope
        )
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
        trustCache = IrxBrokerCacheFactory.make(
            kind: "trust",
            fileURL: dir.appendingPathComponent("trust.json"),
            scope: scope
        )
        credentialCache = IrxBrokerCacheFactory.make(
            kind: "relay-credentials",
            fileURL: dir.appendingPathComponent("relay-credentials.json"),
            scope: scope
        )
        grantCache = IrxBrokerCacheFactory.make(
            kind: "grants",
            fileURL: dir.appendingPathComponent("grants.json"),
            scope: scope
        )
    }

    /// The underlying trust-broker client, exposed for the legacy-dialect
    /// admission registry (online revalidation parity for old phones).
    public nonisolated var hostBrokerClient: CmxIrohTrustBrokerClient { client }

    // MARK: - Registration

    public func cachedBinding() -> IrxBindingSnapshot? {
        guard !deactivated else { return nil }
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
        let epoch = try beginOperation()
        if let registrationInFlight {
            return try await registrationInFlight.value
        }
        let task = Task<IrxBindingSnapshot, any Error> {
            try await self.registerOnce(
                pairingEnabled: pairingEnabled,
                relayURLHint: relayURLHint,
                directPorts: directPorts,
                epoch: epoch
            )
        }
        registrationInFlight = task
        defer { registrationInFlight = nil }
        return try await task.value
    }

    private func registerOnce(
        pairingEnabled: Bool,
        relayURLHint: String?,
        directPorts: CmxIrohDirectPorts?,
        epoch: UInt64
    ) async throws -> IrxBindingSnapshot {
        try requireCurrent(epoch)
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
        try requireCurrent(epoch)
        let snapshot = IrxBindingSnapshot(
            bindingID: response.binding.bindingID,
            deviceID: response.binding.deviceID,
            tag: response.binding.tag,
            endpointIDHex: identity.endpointIDHex,
            identityGeneration: response.binding.identityGeneration,
            registeredAt: Date()
        )
        try requireCurrent(epoch)
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
        guard !deactivated else { return nil }
        return trustCache.load()
    }

    /// Synchronous trust read for the admission path (no actor hop). Reads
    /// the SAME cache the discovery write path uses, so the Release keychain
    /// migration can never strand admission on a deleted legacy file.
    public nonisolated func cachedTrustForAdmission() -> IrxTrustSnapshot? {
        trustCache.load()
    }

    /// Fresh-enough discovery, from memory or the wire. Never called on the
    /// admission path; admission uses `cachedTrust()`.
    public func discover(maximumAge: TimeInterval = 30) async throws -> CmxIrohDiscoveryResponse {
        let epoch = try beginOperation()
        if let lastDiscovery, let lastDiscoveryAt,
            Date().timeIntervalSince(lastDiscoveryAt) < maximumAge
        {
            return lastDiscovery
        }
        let startedAt = DispatchTime.now()
        let response = try await client.discover()
        try requireCurrent(epoch)
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

    /// Drops the in-memory discovery snapshot after a presence push proves it
    /// stale, so the next discovery-consuming call refetches.
    public func invalidateDiscoverySnapshot() {
        guard !deactivated else { return }
        lastDiscovery = nil
        lastDiscoveryAt = nil
    }

    /// Revokes one account-owned binding (the "forget computer" server leg).
    public func revoke(bindingID: String) async throws {
        let epoch = try beginOperation()
        try await client.revoke(bindingID: bindingID)
        try requireCurrent(epoch)
        journal.record("broker", "binding-revoked", ["binding": bindingID])
    }

    // MARK: - Relay credentials

    public func cachedRelayCredentials() -> [IrxRelayCredential] {
        guard !deactivated else { return [] }
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
        let epoch = try beginOperation()
        let startedAt = DispatchTime.now()
        let endpointID = try CmxIrohPeerIdentity(endpointID: identity.endpointIDHex)
        // Union of both mint hardenings: the stale-pooled-connection retry
        // (first POST after idle dies on a dead keep-alive socket) wraps the
        // call, and a proof rejection still invalidates the cached binding so
        // the next attempt re-registers instead of looping unsigned.
        let bootstrap: CmxIrohRelayBootstrapResponse
        do {
            bootstrap = try await issueRelayBootstrapRetryingStaleConnection(
                endpointID: endpointID
            )
            try requireCurrent(epoch)
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
        try requireCurrent(epoch)
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

    /// Accepts control-plane-pushed relay credentials under the SAME rules as
    /// a mint: every relay must be in the authenticated fleet allowlist, the
    /// snapshot is identity-bound, and freshness is monotonic (pushed passes
    /// that don't outlive the cached set are dropped, so a delayed push can
    /// never regress local state). Returns the accepted set, or nil.
    public func acceptPushedRelayCredentials(
        _ pushed: [IrxRelayCredential]
    ) -> [IrxRelayCredential]? {
        guard !deactivated else { return nil }
        guard !pushed.isEmpty else { return nil }
        let allowedFleet = Set(trustCache.load()?.relayFleet ?? [])
        guard allowedFleet.isEmpty == false,
            pushed.allSatisfy({ allowedFleet.contains($0.relayURL) })
        else {
            journal.record(
                "broker", "pushed-credentials-rejected",
                ["reason": "fleet-allowlist"]
            )
            return nil
        }
        let cachedSnapshot = credentialCache.load().flatMap { snapshot in
            snapshot.endpointIDHex == identity.endpointIDHex ? snapshot : nil
        }
        var mergedByRelay = Dictionary(
            uniqueKeysWithValues: (cachedSnapshot?.credentials ?? []).map {
                ($0.relayURL, $0)
            })
        var accepted: [IrxRelayCredential] = []
        let now = Date()
        for credential in pushed {
            guard credential.expiresAt > now,
                credential.refreshAfter < credential.expiresAt
            else { continue }
            guard
                mergedByRelay[credential.relayURL].map({
                    credential.expiresAt > $0.expiresAt
                }) ?? true
            else { continue }
            mergedByRelay[credential.relayURL] = credential
            accepted.append(credential)
        }
        guard !accepted.isEmpty else {
            journal.record(
                "broker", "pushed-credentials-rejected", ["reason": "stale"]
            )
            return nil
        }
        let pushedMax = accepted.map(\.expiresAt).max() ?? .distantPast
        credentialCache.save(
            IrxRelayCredentialSnapshot(
                credentials: mergedByRelay.values.sorted { $0.relayURL < $1.relayURL },
                mintedAt: Date(),
                endpointIDHex: identity.endpointIDHex
            ))
        journal.record(
            "broker", "relay-passes-pushed",
            [
                "relays": accepted.map(\.relayURL).joined(separator: ","),
                "expires_at": ISO8601DateFormatter().string(from: pushedMax),
            ]
        )
        return accepted
    }

    /// One immediate retry for the connection-reuse failure class.
    ///
    /// The autopilot mints every ~3-4 minutes, longer than the broker edge's
    /// idle keep-alive window, so the first POST of a cycle deterministically
    /// lands on a pooled connection the server already closed: the write
    /// succeeds into the dead socket, the first read fails with ECONNRESET,
    /// and URLSession surfaces NSURLErrorNetworkConnectionLost (-1005)
    /// without a transparent retry because the POST body was already written
    /// (Apple QA1941). That failure also purged the dead pooled connection,
    /// so one immediate retry runs on a fresh connection. Minting is
    /// idempotent, the retry is bounded to exactly one attempt for exactly
    /// this failure class, and the autopilot's half-remaining-validity sleep
    /// loop stays the outer safety net for everything else.
    private func issueRelayBootstrapRetryingStaleConnection(
        endpointID: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRelayBootstrapResponse {
        do {
            return try await client.issueRelayBootstrap(endpointID: endpointID)
        } catch let error as CmxIrohTrustBrokerClientError {
            guard case let .connectivity(cause?) = error,
                cause.isConnectionReuseFailure
            else { throw error }
            journal.record(
                "broker", "relay-mint-retried",
                ["error": String(describing: error)]
            )
            return try await client.issueRelayBootstrap(endpointID: endpointID)
        }
    }

    // MARK: - Pair grants (keyed by the acceptor's endpoint, what routes carry)

    public func cachedGrant(
        acceptorEndpointIDHex: String,
        now: Date = Date()
    ) -> IrxGrantSnapshot? {
        guard !deactivated else { return nil }
        guard let grants = grantCache.load(),
            let snapshot = grants[acceptorEndpointIDHex],
            snapshot.isFresh(at: now)
        else { return nil }
        return snapshot
    }

    /// Drops a grant the host just refused, so the next dial re-mints
    /// instead of re-presenting stale cache.
    public func dropGrant(acceptorEndpointIDHex: String) {
        guard !deactivated else { return }
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
        let epoch = try beginOperation()
        guard let binding = cachedBinding() else {
            throw IrxBrokerServiceError.notRegistered
        }
        let response: CmxIrohPairGrantResponse
        do {
            response = try await client.issuePairGrant(
                initiatorBindingID: binding.bindingID,
                acceptorBindingID: acceptorBindingID
            )
            try requireCurrent(epoch)
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
        try requireCurrent(epoch)
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

    /// Invalidates this broker instance and erases every endpoint-bearing
    /// cache. The instance is discarded after sign-out. The epoch fence is
    /// required because cancelling URLSession does not guarantee that a late
    /// response cannot resume and attempt a cache write.
    public func deactivate() {
        lifecycleEpoch &+= 1
        deactivated = true
        registrationInFlight?.cancel()
        registrationInFlight = nil
        lastHintRegistered = nil
        lastDiscovery = nil
        lastDiscoveryAt = nil
        bindingCache.clear()
        trustCache.clear()
        credentialCache.clear()
        grantCache.clear()
        journal.record("broker", "deactivated")
    }

    private func beginOperation() throws -> UInt64 {
        guard !deactivated else { throw IrxBrokerServiceError.deactivated }
        return lifecycleEpoch
    }

    private func requireCurrent(_ epoch: UInt64) throws {
        guard !deactivated, lifecycleEpoch == epoch else {
            throw IrxBrokerServiceError.deactivated
        }
    }
}
