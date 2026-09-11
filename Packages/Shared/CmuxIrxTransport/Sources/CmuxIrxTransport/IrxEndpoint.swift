public import Foundation
public import IrohLib

public enum IrxEndpointError: Error, Sendable {
    case noUsableRelayCredential
    case endpointClosed
    case bindFailed(String)
    case noDirectAddress
}

/// How the endpoint constrains paths. `relayOnly` is the soak/reliability
/// mode: dial addresses carry only the relay URL and NAT traversal is never
/// authorized, so every byte stays on the relay fleet.
public enum IrxPathMode: String, Sendable {
    case automatic
    case relayOnly = "relay-only"
    /// Explicit local routes use an endpoint with all relay transport disabled.
    case directOnly = "direct-only"
}

public struct IrxEndpointConfiguration: Sendable {
    public var identity: IrxIdentity
    public var pathMode: IrxPathMode
    /// Preferred UDP bind, e.g. "0.0.0.0:58470" on the Mac host; nil = ephemeral.
    public var preferredBindAddress: String?
    /// The remote side may open this many concurrent bidi streams before any
    /// post-admission raise. Server: 1 (the control stream). Client: 0.
    public var initialRemoteBiStreams: UInt64
    /// Same for unidirectional streams (client raises to accept the server's
    /// events lane only after admission).
    public var initialRemoteUniStreams: UInt64
    /// Extra ALPNs served on the SAME endpoint/identity (the legacy dialect
    /// for old phones). Accepted connections route by the protocol the
    /// dialer spoke; irx never shares session state with them.
    public var additionalALPNs: [Data]

    public init(
        identity: IrxIdentity,
        pathMode: IrxPathMode,
        preferredBindAddress: String? = nil,
        initialRemoteBiStreams: UInt64,
        initialRemoteUniStreams: UInt64,
        additionalALPNs: [Data] = []
    ) {
        self.identity = identity
        self.pathMode = pathMode
        self.preferredBindAddress = preferredBindAddress
        self.initialRemoteBiStreams = initialRemoteBiStreams
        self.initialRemoteUniStreams = initialRemoteUniStreams
        self.additionalALPNs = additionalALPNs
    }
}

/// Owns one iroh endpoint generation: binds it with the current relay
/// credentials, reports readiness BEFORE anyone may dial (the old stack's
/// launch dial race caused 286 field failures), rotates credentials in place
/// with insertRelay alone, and rebinds a new generation when the driver dies.
public actor IrxEndpointSupervisor {
    private let configuration: IrxEndpointConfiguration
    private let journal: IrxJournal
    private var driver: Endpoint?
    private var generation = 0
    private var onlineReached = false
    private var closeWatcher: Task<Void, Never>?
    private var installedRelayURLs: Set<String> = []
    private var desiredRelayCredentials: [IrxRelayCredential]?
    private var relayInstaller: IrxRelayCredentialInstaller?
    private var bindInFlight: Task<Endpoint, any Error>?
    private var bindID: UUID?
    /// Sign-out invalidates this supervisor permanently. A cancelled bind can
    /// still resume after URLSession/iroh returns, so the epoch is checked
    /// before that stale endpoint is published or advertised.
    private var lifecycleEpoch: UInt64 = 0
    private var deactivated = false

    public init(configuration: IrxEndpointConfiguration, journal: IrxJournal) {
        self.configuration = configuration
        self.journal = journal
    }

    public var currentGeneration: Int { generation }

    public func identity() -> IrxIdentity { configuration.identity }

    /// Returns a ready endpoint, binding one if needed. Direct-only mode is
    /// ready after the UDP bind and never requires a relay credential.
    /// Single-flight: concurrent callers join the in-progress bind.
    public func readyEndpoint(credentials: [IrxRelayCredential]) async throws -> Endpoint {
        guard !deactivated else { throw IrxEndpointError.endpointClosed }
        if let driver, driver.isClosed() == false, onlineReached {
            return driver
        }
        if let bindInFlight {
            return try await bindInFlight.value
        }
        let epoch = lifecycleEpoch
        let id = UUID()
        let task = Task<Endpoint, any Error> {
            try await bindGeneration(credentials: credentials, epoch: epoch)
        }
        bindInFlight = task
        bindID = id
        defer {
            if bindID == id { bindInFlight = nil; bindID = nil }
        }
        return try await task.value
    }

    /// The bound endpoint if one exists (no bind side effects).
    public func boundEndpoint() -> Endpoint? {
        guard let driver, !driver.isClosed() else { return nil }
        return driver
    }

    /// Actual UDP port, including a fallback bind. Used only for local settings.
    public func boundPort() -> Int? {
        guard let driver, !driver.isClosed() else { return nil }
        return driver.boundSockets().compactMap { address in
            URLComponents(string: "udp://" + address)?.port
        }.first { (1...65535).contains($0) }
    }

    /// The relay this endpoint actually homes on (post-`online`), the URL
    /// peers should dial first. Never assume it equals any credential's URL.
    public func homeRelayURL() -> String? {
        guard let driver, !driver.isClosed() else { return nil }
        return driver.addr().relayUrl()
    }

    /// Returns the endpoint's current direct candidates. Iroh owns candidate
    /// discovery and NAT traversal. These addresses remain on the devices;
    /// the backend stores only relay URLs. Relay-only mode returns no candidates.
    public func localDirectAddresses() -> [String] {
        guard configuration.pathMode != .relayOnly,
              let driver,
              !driver.isClosed() else { return [] }
        return driver.addr().directAddresses()
    }

    /// One accepted inbound connection, routed by the ALPN the dialer spoke.
    public enum AcceptedInbound: Sendable {
        case irx(IrxConnection)
        /// A non-irx protocol this endpoint also serves (legacy dialect).
        case foreign(alpn: Data, connection: Connection)
    }

    /// Accepts the next inbound connection, or nil when the endpoint is
    /// closed/unbound (callers rebind via `readyEndpoint`).
    public func acceptNextInbound() async -> AcceptedInbound? {
        guard let driver, !driver.isClosed() else { return nil }
        guard let incoming = await driver.acceptNext() else { return nil }
        do {
            let accepting = try await incoming.accept()
            let alpn = try await accepting.alpn()
            let connection = try await accepting.connect()
            if alpn == IrxProtocol.alpnData {
                return .irx(
                    IrxConnection(connection: connection, role: .acceptor, journal: journal))
            }
            journal.record(
                "endpoint", "foreign-alpn-accepted",
                ["alpn": String(data: alpn, encoding: .utf8) ?? "?"]
            )
            return .foreign(alpn: alpn, connection: connection)
        } catch {
            journal.record(
                "endpoint", "accept-failed",
                ["error": String(describing: error)]
            )
            return nil
        }
    }

    /// Make-before-break rotation: insert the fresh credential for each URL;
    /// the forked iroh authenticates a replacement relay connection before
    /// swapping routes, so live sessions continue. Never removeRelay for a
    /// URL being rotated - remove tears the active relay down instantly.
    /// Queues a serialized installation and retries local failures independently
    /// of credential minting. Native installation emits its own outcome event.
    public func rotateCredentials(_ credentials: [IrxRelayCredential]) async {
        guard !deactivated, configuration.pathMode != .directOnly else { return }
        desiredRelayCredentials = credentials
        await relayInstaller?.replace(with: credentials)
    }

    /// Rotates relay credentials only while the caller still owns the current
    /// autopilot lifecycle. The ownership check is deliberately inside this
    /// actor, after any broker await in the caller, so an older refresh task
    /// cannot mutate a newer endpoint lifecycle.
    func rotateCredentialsIfCurrent(
        _ credentials: [IrxRelayCredential],
        rotationGeneration: UInt64,
        gate: IrxRelayCredentialRotationGate
    ) async {
        guard configuration.pathMode != .directOnly else { return }
        guard await gate.isCurrent(rotationGeneration) else { return }
        guard !deactivated else { return }
        guard let driver, !driver.isClosed() else { return }
        let endpointGeneration = generation
        for credential in credentials {
            let result = await gate.withCurrentMutation(rotationGeneration) {
                do {
                    try await driver.insertRelay(
                        config: RelayConfig(
                            url: credential.relayURL,
                            quicPort: nil,
                            authToken: credential.token
                        )
                    )
                    return IrxRelayCredentialMutationResult.success
                } catch {
                    return IrxRelayCredentialMutationResult.failure(
                        String(describing: error)
                    )
                }
            }
            guard let result else { return }
            switch result {
            case .success:
                guard await gate.isCurrent(rotationGeneration),
                      !deactivated,
                      generation == endpointGeneration,
                      let currentDriver = self.driver,
                      !currentDriver.isClosed()
                else { return }
                installedRelayURLs.insert(credential.relayURL)
                journal.record(
                    "endpoint", "relay-credential-rotated",
                    [
                        "relay": credential.relayURL,
                        "expires_at": ISO8601DateFormatter().string(from: credential.expiresAt),
                        "generation": String(generation),
                    ]
                )
            case .failure(let error):
                guard await gate.isCurrent(rotationGeneration) else { return }
                journal.record(
                    "endpoint", "relay-credential-rotation-failed",
                    ["relay": credential.relayURL, "error": error]
                )
            }
        }
    }

    /// Health check after suspension/resume: a closed driver is replaced on
    /// the next `readyEndpoint` call.
    public func isHealthy() -> Bool {
        guard let driver else { return false }
        return !driver.isClosed() && onlineReached
    }

    public func close() async {
        lifecycleEpoch &+= 1
        bindInFlight?.cancel()
        bindInFlight = nil
        bindID = nil
        closeWatcher?.cancel()
        closeWatcher = nil
        let installer = relayInstaller
        relayInstaller = nil
        let old = driver
        driver = nil
        onlineReached = false
        await installer?.stop()
        if let old { try? await old.close() }
        journal.record("endpoint", "closed", ["generation": String(generation)])
    }

    /// Sign-out permanently prevents this supervisor from accepting more work.
    public func deactivate() async {
        deactivated = true
        desiredRelayCredentials = nil
        await close()
        journal.record("endpoint", "deactivated")
    }

    private func discardBinding(_ bound: Endpoint) async {
        if driver === bound {
            let installer = relayInstaller
            relayInstaller = nil
            driver = nil
            onlineReached = false
            closeWatcher?.cancel()
            closeWatcher = nil
            await installer?.stop()
        }
        try? await bound.close()
    }

    private func bindGeneration(
        credentials: [IrxRelayCredential],
        epoch: UInt64
    ) async throws -> Endpoint {
        guard !deactivated, epoch == lifecycleEpoch else {
            throw IrxEndpointError.endpointClosed
        }
        if let old = driver {
            await discardBinding(old)
            guard !deactivated, epoch == lifecycleEpoch else { throw IrxEndpointError.endpointClosed }
        }
        let now = Date()
        let directOnly = configuration.pathMode == .directOnly
        let usable = directOnly ? [] : (desiredRelayCredentials ?? credentials).filter { $0.isUsable(at: now) }
        guard directOnly || !usable.isEmpty else {
            journal.record("endpoint", "bind-refused-no-credential")
            throw IrxEndpointError.noUsableRelayCredential
        }
        generation += 1
        let startedAt = DispatchTime.now()
        let relayMap = RelayMap.empty()
        for credential in usable {
            try relayMap.insert(
                config: RelayConfig(
                    url: credential.relayURL,
                    quicPort: nil,
                    authToken: credential.token
                )
            )
        }
        var options = EndpointOptions(preset: presetMinimal())
        options.secretKey = configuration.identity.privateKeyData
        options.alpns = [IrxProtocol.alpnData] + configuration.additionalALPNs
        options.relayMode = directOnly ? RelayMode.disabled() : RelayMode.custom(map: relayMap)
        options.portMappingEnabled = false
        // NAT traversal stays unauthorized until admission (automatic mode) or
        // forever (relay-only mode); the authorize call is per-connection.
        options.deferNatTraversalUntilAuthorized = true
        options.initialMaxConcurrentBiStreams = configuration.initialRemoteBiStreams
        options.initialMaxConcurrentUniStreams = configuration.initialRemoteUniStreams
        if let preferred = configuration.preferredBindAddress {
            options.bindAddr = preferred
        }
        let bound: Endpoint
        do {
            bound = try await Endpoint.bind(options: options)
        } catch where configuration.preferredBindAddress != nil {
            guard !Task.isCancelled, !deactivated, epoch == lifecycleEpoch else {
                throw IrxEndpointError.endpointClosed
            }
            // Preferred-port squatting falls back to an ephemeral bind; the
            // advertised route always reflects the port actually bound.
            options.bindAddr = nil
            bound = try await Endpoint.bind(options: options)
        }
        guard !deactivated, epoch == lifecycleEpoch else {
            try? await bound.close()
            throw IrxEndpointError.endpointClosed
        }
        driver = bound
        if !directOnly {
            let installer = IrxRelayCredentialInstaller(installed: usable, journal: journal) { credential in
                try await bound.insertRelay(config: RelayConfig(
                    url: credential.relayURL, quicPort: nil, authToken: credential.token))
            }
            relayInstaller = installer
            await installer.replace(with: desiredRelayCredentials ?? usable)
            guard !deactivated, epoch == lifecycleEpoch else {
                await installer.stop()
                try? await bound.close()
                throw IrxEndpointError.endpointClosed
            }
        }
        installedRelayURLs = Set(usable.map(\.relayURL))
        journal.record(
            "endpoint", "bound",
            [
                "generation": String(generation),
                "endpoint_id": configuration.identity.endpointIDHex,
                "relays": usable.map(\.relayURL).joined(separator: ","),
                "path_mode": configuration.pathMode.rawValue,
            ]
        )
        if directOnly {
            onlineReached = true
            watchClosure(of: bound, generation: generation)
            journal.record("endpoint", "direct-ready", ["generation": String(generation)])
            return bound
        }
        // Readiness = the relay link is up. Dials before this point are the
        // old stack's launch race; callers await readiness instead. Bounded:
        // a relay that never admits us (e.g. a silently refused wrong-key
        // token) must fail the bind loudly, not hang activation forever.
        let cameOnline: Bool?
        do {
            cameOnline = try await withIrxDeadline(.seconds(20), onTimeout: {
                try? await bound.close()
            }) {
                await bound.online()
                return true
            }
        } catch {
            await discardBinding(bound)
            throw error
        }
        guard !deactivated, epoch == lifecycleEpoch else {
            await discardBinding(bound)
            throw IrxEndpointError.endpointClosed
        }
        guard cameOnline == true else {
            journal.record(
                "endpoint", "online-timeout",
                ["generation": String(generation)]
            )
            await discardBinding(bound)
            throw IrxEndpointError.bindFailed("relay link never came up (20s)")
        }
        onlineReached = true
        let readyMs =
            (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        journal.record(
            "endpoint", "online",
            ["generation": String(generation), "bind_to_online_ms": String(readyMs)]
        )
        watchClosure(of: bound, generation: generation)
        return bound
    }

    private func watchClosure(of endpoint: Endpoint, generation: Int) {
        closeWatcher?.cancel()
        closeWatcher = Task { [weak self] in
            await endpoint.closed()
            guard !Task.isCancelled else { return }
            await self?.driverDidClose(generation: generation)
        }
    }

    private func driverDidClose(generation closedGeneration: Int) async {
        guard closedGeneration == generation else { return }
        let installer = relayInstaller
        relayInstaller = nil
        driver = nil
        onlineReached = false
        journal.record("endpoint", "closed-unexpectedly", ["generation": String(closedGeneration)])
        await installer?.stop()
    }
}

extension IrxEndpointSupervisor {
    /// Builds the dial address for a peer under the configured path mode.
    /// Relay-only carries NO direct candidates, so the connection can only
    /// establish through the relay.
    public nonisolated func dialAddress(
        peerEndpointIDHex: String,
        relayURL: String?,
        directAddresses: [String]
    ) throws -> EndpointAddr {
        let id = try EndpointId.fromString(s: peerEndpointIDHex)
        switch configuration.pathMode {
        case .relayOnly:
            return EndpointAddr(id: id, relayUrl: relayURL, addresses: [])
        case .automatic:
            return EndpointAddr(id: id, relayUrl: relayURL, addresses: directAddresses)
        case .directOnly:
            guard !directAddresses.isEmpty else { throw IrxEndpointError.noDirectAddress }
            return EndpointAddr(id: id, relayUrl: nil, addresses: directAddresses)
        }
    }

    /// Dials a peer through the ready endpoint. The caller supplies current
    /// credentials so a cold supervisor can bind on the way (cached
    /// credentials make this a zero-network fast path).
    public func dial(
        address: EndpointAddr,
        credentials: [IrxRelayCredential]
    ) async throws -> IrxConnection {
        let target: EndpointAddr
        if configuration.pathMode == .directOnly {
            guard !address.directAddresses().isEmpty else { throw IrxEndpointError.noDirectAddress }
            target = EndpointAddr(id: address.id(), relayUrl: nil, addresses: address.directAddresses())
        } else { target = address }
        let endpoint = try await readyEndpoint(credentials: credentials)
        let startedAt = DispatchTime.now()
        let connection = try await endpoint.connect(
            addr: target, alpn: IrxProtocol.alpnData)
        let elapsedMs =
            (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        let irx = IrxConnection(connection: connection, role: .dialer, journal: journal)
        journal.record(
            "endpoint", "dialed",
            [
                "remote": String(irx.remoteEndpointIDHex.prefix(12)),
                "elapsed_ms": String(elapsedMs),
                "path": irx.selectedPathDescription(),
            ]
        )
        return irx
    }
}
