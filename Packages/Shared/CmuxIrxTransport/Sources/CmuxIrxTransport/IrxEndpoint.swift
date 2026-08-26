public import Foundation
public import IrohLib

public enum IrxEndpointError: Error, Sendable {
    case noUsableRelayCredential
    case endpointClosed
    case bindFailed(String)
}

/// How the endpoint constrains paths. `relayOnly` is the soak/reliability
/// mode: dial addresses carry only the relay URL and NAT traversal is never
/// authorized, so every byte stays on the relay fleet.
public enum IrxPathMode: String, Sendable {
    case automatic
    case relayOnly = "relay-only"
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

    public init(
        identity: IrxIdentity,
        pathMode: IrxPathMode,
        preferredBindAddress: String? = nil,
        initialRemoteBiStreams: UInt64,
        initialRemoteUniStreams: UInt64
    ) {
        self.identity = identity
        self.pathMode = pathMode
        self.preferredBindAddress = preferredBindAddress
        self.initialRemoteBiStreams = initialRemoteBiStreams
        self.initialRemoteUniStreams = initialRemoteUniStreams
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
    private var bindInFlight: Task<Endpoint, any Error>?

    public init(configuration: IrxEndpointConfiguration, journal: IrxJournal) {
        self.configuration = configuration
        self.journal = journal
    }

    public var currentGeneration: Int { generation }

    public func identity() -> IrxIdentity { configuration.identity }

    /// Returns a bound, relay-online endpoint, binding one if needed.
    /// Single-flight: concurrent callers join the in-progress bind.
    public func readyEndpoint(credentials: [IrxRelayCredential]) async throws -> Endpoint {
        if let driver, driver.isClosed() == false, onlineReached {
            return driver
        }
        if let bindInFlight {
            return try await bindInFlight.value
        }
        let task = Task<Endpoint, any Error> {
            try await bindGeneration(credentials: credentials)
        }
        bindInFlight = task
        defer { bindInFlight = nil }
        return try await task.value
    }

    /// The bound endpoint if one exists (no bind side effects).
    public func boundEndpoint() -> Endpoint? {
        guard let driver, !driver.isClosed() else { return nil }
        return driver
    }

    /// The relay this endpoint actually homes on (post-`online`), the URL
    /// peers should dial first. Never assume it equals any credential's URL.
    public func homeRelayURL() -> String? {
        guard let driver, !driver.isClosed() else { return nil }
        return driver.addr().relayUrl()
    }

    /// Accepts the next inbound connection as an irx connection, or nil when
    /// the endpoint is closed/unbound (callers rebind via `readyEndpoint`).
    public func acceptNextIrxConnection() async -> IrxConnection? {
        guard let driver, !driver.isClosed() else { return nil }
        guard let incoming = await driver.acceptNext() else { return nil }
        do {
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            return IrxConnection(connection: connection, role: .acceptor, journal: journal)
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
    public func rotateCredentials(_ credentials: [IrxRelayCredential]) async {
        guard let driver, !driver.isClosed() else { return }
        for credential in credentials {
            do {
                try await driver.insertRelay(
                    config: RelayConfig(
                        url: credential.relayURL,
                        quicPort: nil,
                        authToken: credential.token
                    )
                )
                installedRelayURLs.insert(credential.relayURL)
                journal.record(
                    "endpoint", "relay-credential-rotated",
                    [
                        "relay": credential.relayURL,
                        "expires_at": ISO8601DateFormatter().string(from: credential.expiresAt),
                        "generation": String(generation),
                    ]
                )
            } catch {
                journal.record(
                    "endpoint", "relay-credential-rotation-failed",
                    ["relay": credential.relayURL, "error": String(describing: error)]
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
        closeWatcher?.cancel()
        closeWatcher = nil
        if let driver {
            try? await driver.close()
        }
        driver = nil
        onlineReached = false
        journal.record("endpoint", "closed", ["generation": String(generation)])
    }

    private func bindGeneration(credentials: [IrxRelayCredential]) async throws -> Endpoint {
        if let old = driver {
            try? await old.close()
            driver = nil
            onlineReached = false
        }
        let now = Date()
        let usable = credentials.filter { $0.isUsable(at: now) }
        guard !usable.isEmpty else {
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
        options.alpns = [IrxProtocol.alpnData]
        options.relayMode = RelayMode.custom(map: relayMap)
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
            // Preferred-port squatting falls back to an ephemeral bind; the
            // advertised route always reflects the port actually bound.
            options.bindAddr = nil
            bound = try await Endpoint.bind(options: options)
        }
        driver = bound
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
        // Readiness = the relay link is up. Dials before this point are the
        // old stack's launch race; callers await readiness instead.
        await bound.online()
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

    private func driverDidClose(generation closedGeneration: Int) {
        guard closedGeneration == generation else { return }
        journal.record(
            "endpoint", "closed-unexpectedly",
            ["generation": String(closedGeneration)]
        )
        driver = nil
        onlineReached = false
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
        }
    }

    /// Dials a peer through the ready endpoint. The caller supplies current
    /// credentials so a cold supervisor can bind on the way (cached
    /// credentials make this a zero-network fast path).
    public func dial(
        address: EndpointAddr,
        credentials: [IrxRelayCredential]
    ) async throws -> IrxConnection {
        let endpoint = try await readyEndpoint(credentials: credentials)
        let startedAt = DispatchTime.now()
        let connection = try await endpoint.connect(
            addr: address, alpn: IrxProtocol.alpnData)
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
