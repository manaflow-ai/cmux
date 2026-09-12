import Foundation
public import IrohLib

/// The iroh-mode substrate (contract 2.1, D7 rung 1): real QUIC connections
/// via stock upstream iroh (cmux-lite IrohLib branch), plugged into the same
/// `PeerConnection` seam the loopback implements. Lanes map one-to-one onto
/// bidirectional QUIC streams, so cross-lane independence (5.2) is physical.
public struct IrohSubstrate: Sendable {
    /// Creates the stateless IrohSubstrate operation value.
    public init() {}

    /// ALPN bytes matching the protocol identifier used by the admission exchange.
    public var alpn: Data { Data(Frame.protocolIdentifier.utf8) }

    /// Build and bind an endpoint whose network identity IS the peer identity
    /// (contract 1.1): the Ed25519 key seeds iroh's secret key, so the remote
    /// side's substrate-authenticated key equals `identity.publicKeyData`.
    /// `minimalLoopback` binds to 127.0.0.1 with no relays and no discovery,
    /// for in-process live-QUIC tests; the relay-fleet configuration is P1e.
    /// - Parameters:
    ///   - identity: Signing key to use as the endpoint's network identity.
    ///   - minimalLoopback: Whether to bind only loopback for isolated tests.
    /// - Returns: A bound endpoint; the caller owns its shutdown.
    /// - Throws: Identity configuration or endpoint bind errors.
    #if compiler(>=6.2)
    @concurrent
    #endif
    public func endpoint(
        identity: PeerIdentity, minimalLoopback: Bool
    ) async throws -> Endpoint {
        let builder = EndpointBuilder()
        builder.applyMinimal()
        try builder.secretKey(bytes: identity.privateKeyData)
        builder.alpns(alpns: [alpn])
        if minimalLoopback {
            try builder.bindAddr(addr: "127.0.0.1:0")
        }
        let endpoint = try await builder.bind()
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                endpoint bound id=\(TransportDebugLog.hex8(endpoint.id().toBytes()), privacy: .public) \
                device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                relays=0 loopback=\(minimalLoopback, privacy: .public) \
                sockets=\(endpoint.boundSockets().count, privacy: .public)
                """)
        }
        return endpoint
    }

    /// One authenticated relay (contract 9.1): our fleet requires an
    /// endpoint-bound token on the websocket upgrade. Rotation: `insertRelay`
    /// ALONE with the fresh token — our iroh fork authenticates a replacement
    /// connection before swapping routes, so live sessions continue
    /// (make-before-break). Never removeRelay first: remove cancels the
    /// active relay immediately and severs every session riding it.
    public struct RelayAccess: Sendable {
        /// Relay endpoint URL.
        public var url: String
        /// Optional relay QUIC port override; nil preserves the library default.
        public var quicPort: UInt16?
        /// Optional secret admission token; nil supports modes without client credentials.
        public var authToken: String?

        /// Describes one relay entry without connecting to it.
        /// - Parameters:
        ///   - url: Relay endpoint URL.
        ///   - quicPort: Optional QUIC port override; defaults to the library's choice.
        ///   - authToken: Optional bearer token; defaults to no client credential.
        public init(url: String, quicPort: UInt16? = nil, authToken: String? = nil) {
            self.url = url
            self.quicPort = quicPort
            self.authToken = authToken
        }
    }

    /// Relay-enabled endpoint (P1e): identity-seeded like the loopback
    /// variant, but with a custom relay map pointing at our fleet.
    /// - Parameters:
    ///   - identity: Signing key to use as the endpoint's network identity.
    ///   - relays: Complete initial relay map, including any required credentials.
    /// - Returns: A bound endpoint; relay-online readiness is a separate observation.
    /// - Throws: Invalid identity, relay configuration, or endpoint bind errors.
    #if compiler(>=6.2)
    @concurrent
    #endif
    public func endpoint(
        identity: PeerIdentity, relays: [RelayAccess]
    ) async throws -> Endpoint {
        let builder = EndpointBuilder()
        builder.applyMinimal()
        try builder.secretKey(bytes: identity.privateKeyData)
        builder.alpns(alpns: [alpn])
        let map = RelayMap.empty()
        for relay in relays {
            try map.insert(
                config: RelayConfig(
                    url: relay.url, quicPort: relay.quicPort, authToken: relay.authToken))
        }
        builder.relayMode(mode: RelayMode.custom(map: map))
        let endpoint = try await builder.bind()
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                endpoint bound id=\(TransportDebugLog.hex8(endpoint.id().toBytes()), privacy: .public) \
                device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                relays=\(relays.count, privacy: .public) \
                relayUrls=\(relays.map(\.url).joined(separator: ","), privacy: .public) \
                sockets=\(endpoint.boundSockets().count, privacy: .public)
                """)
        }
        return endpoint
    }

    /// The endpoint key a fleet token is bound to (its JWT `endpoint_id`
    /// claim), or nil if the token doesn't parse. Deterministic and offline.
    /// The relay refuses a wrong-key token with NO client-visible error (the
    /// route just looks dead), so callers must compare this against their own
    /// `identity.publicKeyData` BEFORE dialing and say so loudly on mismatch.
    public func tokenEndpointId(_ token: String) -> Data? {
        guard let hex = tokenClaims(token)?["endpoint_id"]?.stringValue,
            hex.count % 2 == 0
        else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// When a fleet token stops being honored (its JWT `exp` claim, epoch
    /// seconds), or nil if it doesn't parse. Tokens live 300s; dialing with
    /// an expired one makes the relay route silently dead, so callers should
    /// name it (the 08-21 "chat died at +5min" field bite).
    public func tokenExpiry(_ token: String) -> Int64? {
        tokenClaims(token)?["exp"]?.intValue
    }

    private func tokenClaims(_ token: String) -> [String: JSONValue]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
    }

    /// A relay-only address: no direct candidates at all, so the connection
    /// can only be established through the relay (harness spec 2.2).
    public func relayAddr(id: Data, relayUrl: String) throws -> EndpointAddr {
        EndpointAddr(id: try EndpointId.fromBytes(bytes: id), relayUrl: relayUrl, addresses: [])
    }

    /// The dialable address of a bound endpoint, for tests and LAN dials.
    public func directAddr(of endpoint: Endpoint) -> EndpointAddr {
        let addresses = endpoint.boundSockets().map {
            $0.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
        }
        return EndpointAddr(id: endpoint.id(), relayUrl: nil, addresses: addresses)
    }

    /// Establishes QUIC and starts lane acceptance with cancellation-safe ownership transfer.
    /// - Parameters:
    ///   - endpoint: Bound local endpoint, owned by the caller.
    ///   - addr: Remote identity and current direct/relay routing hints.
    /// - Returns: A dialer-side connection; application admission has not run yet.
    /// - Throws: Cancellation or an underlying connection error.
    #if compiler(>=6.2)
    @concurrent
    #endif
    public func dial(
        endpoint: Endpoint, to addr: EndpointAddr
    ) async throws -> IrohPeerConnection {
        let dialStart = ContinuousClock.now
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                substrate dial begin target=\(TransportDebugLog.hex8(addr.id().toBytes()), privacy: .public) \
                addrs=\(addr.directAddresses().count, privacy: .public) \
                relay=\(addr.relayUrl() ?? "none", privacy: .public)
                """)
        }
        let peer: IrohPeerConnection
        do {
            // Keep the cancellable ConnectAttempt handle alive for the whole
            // FFI handshake. A timeout or owner shutdown cancels this task;
            // the attempt's Rust cancellation token then releases a UDP
            // blackhole instead of leaving the caller parked in `connect()`.
            let attempt = try endpoint.beginConnect(addr: addr, alpn: alpn)
            peer = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await startPeer(role: .dialer) { try await attempt.connect() }
            }, onCancel: {
                attempt.cancel()
            })
        } catch {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    substrate dial FAILED target=\(TransportDebugLog.hex8(addr.id().toBytes()), privacy: .public) \
                    error=\(String(describing: error), privacy: .public) \
                    elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public)
                    """)
            }
            throw error
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                substrate dial connected conn=\(TransportDebugLog.id(peer), privacy: .public) \
                remote=\(TransportDebugLog.hex8(peer.remoteKey), privacy: .public) \
                elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public)
                """)
        }
        return peer
    }

    /// Pulls and completes the next incoming connection, or returns nil after endpoint closure.
    ///
    /// Cancellation rejects an unconsumed incoming attempt or closes a completed
    /// connection. The endpoint owner must close its endpoint to interrupt a
    /// native accept/handshake that has not returned; closing it here would also
    /// disconnect unrelated sessions on the shared endpoint.
    /// - Parameter endpoint: Shared listening endpoint, owned by the caller.
    /// - Returns: An acceptor peer whose stream task has started, or nil after closure.
    /// - Throws: Cancellation or an underlying handshake error.
    #if compiler(>=6.2)
    @concurrent
    #endif
    public func acceptOne(endpoint: Endpoint) async throws -> IrohPeerConnection? {
        guard let incoming = await endpoint.acceptNext() else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice("substrate acceptOne: endpoint closed (nil incoming)")
            }
            return nil
        }
        do { try Task.checkCancellation() }
        catch {
            try? await incoming.refuse()
            throw error
        }
        let acceptStart = ContinuousClock.now
        let peer: IrohPeerConnection
        do {
            peer = try await startPeer(role: .acceptor) {
                try Task.checkCancellation()
                let accepting = try await incoming.accept()
                // IrohLib's FFI future does not observe Swift task
                // cancellation while the native handshake is pending. If
                // cancellation wins while `accept()` is in flight, this
                // check drops the consumed `Accepting` immediately instead
                // of starting a handshake that no lifecycle owner can keep.
                try Task.checkCancellation()
                return try await accepting.connect()
            }
        } catch {
            // If accept() failed before consuming the incoming, refuse it so
            // a canceled or malformed handshake cannot sit in the endpoint's
            // queue until native timeout. If it was already consumed, the
            // best-effort call is harmless and the Accepting value's drop
            // releases the native handshake.
            try? await incoming.refuse()
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    substrate acceptOne FAILED error=\(String(describing: error), privacy: .public) \
                    elapsedMs=\(TransportDebugLog.ms(since: acceptStart), privacy: .public)
                    """)
            }
            throw error
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                substrate accepted conn=\(TransportDebugLog.id(peer), privacy: .public) \
                remote=\(TransportDebugLog.hex8(peer.remoteKey), privacy: .public) \
                elapsedMs=\(TransportDebugLog.ms(since: acceptStart), privacy: .public)
                """)
        }
        return peer
    }
}
