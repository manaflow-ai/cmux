import Foundation
@preconcurrency import Network
import OSLog

nonisolated private let webClientBridgeLog = Logger(
    subsystem: "dev.cmux",
    category: "web-client-bridge"
)

/// Owns the opt-in browser listener, grants, and connection lifecycle.
///
/// The listener is deliberately separate from the iOS pairing listener. It
/// binds only to a validated loopback or user-selected Tailscale address, and
/// every accepted WebSocket must present a grant in its first message before it
/// enters ``MobileHostConnection``. The Mac app remains the authoritative
/// owner of terminal/workspace state; this type owns only transport lifecycle
/// and browser-grant bookkeeping.
actor WebClientBridgeService {
    static let protocolIdentifier = WebClientWebSocketTransport.protocolIdentifier
    nonisolated private static let defaultPort = 7683
    nonisolated private static let maximumPort = 65535
    nonisolated private static let maximumPendingHandshakeCount = 16

    private let grantStore: WebClientGrantStore
    private let readinessSleep: @Sendable () async throws -> Void
    private let callbackQueue = DispatchQueue(label: "dev.cmux.web-client-bridge.listener")
    private var listener: NWListener?
    private var listenerGeneration = UUID()
    private var bindAddress: WebClientBridgeBindAddress?
    private var requestedPort: Int?
    private var boundPort: Int?
    private var lastError: String?
    private var pendingHandshakeTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingGrantAdmissions: [UUID: (grantID: UUID, gate: WebClientGrantAdmission)] = [:]
    private var revokedGrantIDs: Set<UUID> = []
    private var revokedGrantOrder: [UUID] = []
    private static let maximumRevokedGrantTombstones = 512
    private var readinessWaiters: [CheckedContinuation<MobileHostRPCResult, Never>] = []
    private var readinessTimeoutTask: Task<Void, Never>?

    init(
        grantStore: WebClientGrantStore = WebClientGrantStore(),
        readinessSleep: @escaping @Sendable () async throws -> Void = {
            try await ContinuousClock().sleep(for: .seconds(6))
        }
    ) {
        self.grantStore = grantStore
        self.readinessSleep = readinessSleep
    }

    /// Starts the bridge on an explicit address. The default is loopback and
    /// the listener is never created until this method is called.
    func start(address rawAddress: String = "127.0.0.1", port rawPort: Int = defaultPort) async -> MobileHostRPCResult {
        guard MobileRemoteControlPolicy.isEnabled else {
            return .failure(MobileHostRPCError(
                code: "remote_control_disabled",
                message: String(
                    localized: "webClientBridge.error.remoteControlDisabled",
                    defaultValue: "Remote control is disabled by managed policy."
                )
            ))
        }
        guard let address = try? WebClientBridgeBindAddress(rawAddress) else {
            return .failure(MobileHostRPCError(
                code: "invalid_bind_address",
                message: String(
                    localized: "webClientBridge.error.invalidBindAddress",
                    defaultValue: "Web client bind address must be loopback or a Tailscale 100.64.0.0/10 address; wildcard addresses are refused."
                )
            ))
        }
        guard (0 ... Self.maximumPort).contains(rawPort) else {
            return .failure(MobileHostRPCError(
                code: "invalid_port",
                message: String(
                    localized: "webClientBridge.error.invalidPort",
                    defaultValue: "Web client port must be between 0 and 65535."
                )
            ))
        }
        if listener != nil,
           bindAddress == address,
           requestedPort == rawPort {
            if boundPort != nil {
                return .ok(statusPayload())
            }
            return await waitForReadiness()
        }
        await stopAndWait(readinessResult: .failure(MobileHostRPCError(
            code: "superseded",
            message: String(
                localized: "webClientBridge.error.startSuperseded",
                defaultValue: "Web client bridge startup was replaced by a newer request."
            )
        )))
        do {
            let candidate = try Self.makeListener(
                address: address,
                port: rawPort,
                requestQueue: callbackQueue
            )
            let generation = UUID()
            listenerGeneration = generation
            bindAddress = address
            requestedPort = rawPort
            boundPort = nil
            lastError = nil
            candidate.stateUpdateHandler = { [weak self] state in
                Task { [weak self] in
                    await self?.handleListenerState(state, generation: generation)
                }
            }
            candidate.newConnectionHandler = { [weak self] connection in
                Task { [weak self] in
                    await self?.accept(connection, generation: generation)
                }
            }
            listener = candidate
            candidate.start(queue: callbackQueue)
            return await waitForReadiness()
        } catch {
            lastError = String(describing: error)
            listener = nil
            bindAddress = nil
            requestedPort = nil
            boundPort = nil
            return .failure(MobileHostRPCError(
                code: "bind_failed",
                message: String(
                    localized: "webClientBridge.error.bindFailed",
                    defaultValue: "Unable to bind the web client listener."
                )
            ))
        }
    }

    /// Stops the browser listener and revokes every browser grant. Existing
    /// mobile/iOS connections are untouched.
    func stop() async {
        await stopAndWait()
    }

    private func stopAndWait(readinessResult: MobileHostRPCResult? = nil) async {
        listenerGeneration = UUID()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        bindAddress = nil
        requestedPort = nil
        boundPort = nil
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = nil
        drainReadinessWaiters(readinessResult ?? .ok(statusPayload()))
        let pendingHandshakes = Array(pendingHandshakeTasks.values)
        for pending in pendingGrantAdmissions.values {
            pending.gate.invalidate()
        }
        // Fence already-admitted requests before awaiting any actor work below.
        // A revoke must not let a request that passed the asynchronous grant
        // check reach a terminal mutation while the bridge is stopping.
        MobileHostConnectionRegistry.shared.invalidateAllWebGrantAdmissions()
        let revoked = await grantStore.revokeAll()
        for grantID in revoked {
            rememberRevokedGrant(grantID)
            let connections = MobileHostConnectionRegistry.shared
                .removeWebGrantConnections(grantID)
            for connection in connections {
                await connection.close(reason: "web bridge stopped")
            }
        }
        pendingHandshakeTasks.removeAll()
        for task in pendingHandshakes { task.cancel() }
        for task in pendingHandshakes { await task.value }
    }

    /// Returns listener and redacted-grant state for CLI/settings diagnostics.
    func status() async -> MobileHostRPCResult {
        .ok(await statusPayloadWithGrants())
    }

    /// Issues one new browser grant. The returned token is the only response
    /// that contains it; callers should display it once and then discard it.
    func issueGrant(label: String?) async -> MobileHostRPCResult {
        guard MobileRemoteControlPolicy.isEnabled else {
            return .failure(MobileHostRPCError(
                code: "remote_control_disabled",
                message: String(
                    localized: "webClientBridge.error.remoteControlDisabled",
                    defaultValue: "Remote control is disabled by managed policy."
                )
            ))
        }
        guard listener != nil, boundPort != nil else {
            return .failure(MobileHostRPCError(
                code: "not_running",
                message: String(
                    localized: "webClientBridge.error.notRunning",
                    defaultValue: "Start the web client bridge before creating a browser grant."
                )
            ))
        }
        let issued: WebClientGrantStore.IssuedGrant
        do {
            issued = try await grantStore.issue(label: label)
        } catch WebClientGrantStore.IssueError.limitReached {
            return .failure(MobileHostRPCError(
                code: "grant_limit",
                message: String(
                    localized: "webClientBridge.error.grantLimit",
                    defaultValue: "Too many active browser grants; revoke one before pairing another."
                )
            ))
        } catch {
            return .failure(MobileHostRPCError(
                code: "grant_failed",
                message: String(
                    localized: "webClientBridge.error.grantFailed",
                    defaultValue: "Unable to create browser grant."
                )
            ))
        }
        return .ok([
            "grant": Self.grantPayload(issued.snapshot, connectionCount: 0),
            "token": issued.token,
            "protocol": Self.protocolIdentifier,
        ])
    }

    /// Lists grants without ever returning bearer material.
    func listGrants() async -> MobileHostRPCResult {
        .ok(await grantsPayload())
    }

    /// Revokes exactly one grant and closes only that grant's active sockets.
    func revokeGrant(id: UUID) async -> MobileHostRPCResult {
        guard await grantStore.revoke(id) else {
            return .failure(MobileHostRPCError(
                code: "not_found",
                message: String(
                    localized: "webClientBridge.error.grantNotFound",
                    defaultValue: "Browser grant not found or already revoked."
                )
            ))
        }
        rememberRevokedGrant(id)
        for pending in pendingGrantAdmissions.values where pending.grantID == id {
            pending.gate.invalidate()
        }
        let connections = MobileHostConnectionRegistry.shared.removeWebGrantConnections(id)
        for connection in connections {
            await connection.close(reason: "web grant revoked")
        }
        return .ok([
            "grant_id": id.uuidString,
            "revoked": true,
            "closed_connection_count": connections.count,
        ])
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard listenerGeneration == generation, listener != nil else {
            connection.cancel()
            return
        }
        guard pendingHandshakeTasks.count < Self.maximumPendingHandshakeCount else {
            webClientBridgeLog.warning("web client handshake quota reached; refusing unauthenticated socket")
            connection.cancel()
            return
        }
        let handshakeID = UUID()
        let transport = WebClientWebSocketTransport(
            connection: connection,
            grantStore: grantStore
        )
        let grantStore = self.grantStore
        let task = Task(priority: .userInitiated) { [weak self, grantStore] in
            defer {
                Task { [weak self] in
                    await self?.finishPendingHandshake(handshakeID)
                    await self?.finishGrantAdmission(handshakeID)
                }
            }
            do {
                try await transport.prepare()
                guard let grantID = await transport.authenticatedGrantID() else {
                    await transport.close()
                    return
                }
                guard let admission = await self?.beginGrantAdmission(
                    handshakeID: handshakeID,
                    grantID: grantID,
                    listenerGeneration: generation
                ) else {
                    await transport.close()
                    return
                }
                await self?.finishPendingHandshake(handshakeID)
                guard !Task.isCancelled else {
                    await transport.close()
                    return
                }
                _ = await MobileHostService.acceptTransport(
                    transport,
                    authorization: .webGrant(grantID),
                    webGrantAdmission: admission,
                    webGrantAuthorization: { requestedGrantID, _ in
                        guard MobileRemoteControlPolicy.isEnabled,
                              requestedGrantID == grantID,
                              await grantStore.isActive(requestedGrantID) else {
                            return .failure(MobileHostRPCError(
                                code: MobileRemoteControlPolicy.isDisabled
                                    ? "remote_control_disabled"
                                    : "revoked",
                                message: String(
                                    localized: MobileRemoteControlPolicy.isDisabled
                                        ? "webClientBridge.error.remoteControlDisabled"
                                        : "webClientBridge.error.grantRevoked",
                                    defaultValue: MobileRemoteControlPolicy.isDisabled
                                        ? "Remote control is disabled by managed policy."
                                        : "Browser grant has been revoked"
                                )
                            ))
                        }
                        return nil
                    },
                    isCurrent: {
                        await grantStore.isActive(grantID)
                    }
                )
            } catch {
                if !Task.isCancelled {
                    webClientBridgeLog.error(
                        "web client handshake rejected: \(String(describing: error), privacy: .public)"
                    )
                }
                await transport.close()
            }
        }
        pendingHandshakeTasks[handshakeID] = task
    }

    private func finishPendingHandshake(_ id: UUID) {
        pendingHandshakeTasks[id] = nil
    }

    private func beginGrantAdmission(
        handshakeID: UUID,
        grantID: UUID,
        listenerGeneration: UUID
    ) async -> WebClientGrantAdmission? {
        guard listener != nil,
              listenerGeneration == self.listenerGeneration,
              MobileRemoteControlPolicy.isEnabled,
              !revokedGrantIDs.contains(grantID) else {
            return nil
        }
        guard await grantStore.isActive(grantID) else {
            return nil
        }
        // The store check suspends this actor. Recheck the listener generation
        // and policy after it so a stop/failure that races the lookup cannot
        // admit a late handshake.
        guard listener != nil,
              listenerGeneration == self.listenerGeneration,
              MobileRemoteControlPolicy.isEnabled,
              !revokedGrantIDs.contains(grantID) else {
            return nil
        }
        let gate = WebClientGrantAdmission()
        pendingGrantAdmissions[handshakeID] = (grantID: grantID, gate: gate)
        return gate
    }

    private func finishGrantAdmission(_ id: UUID) {
        pendingGrantAdmissions[id] = nil
    }

    private func rememberRevokedGrant(_ id: UUID) {
        guard revokedGrantIDs.insert(id).inserted else { return }
        revokedGrantOrder.append(id)
        while revokedGrantOrder.count > Self.maximumRevokedGrantTombstones {
            let oldest = revokedGrantOrder.removeFirst()
            revokedGrantIDs.remove(oldest)
        }
    }

    private func handleListenerState(_ state: NWListener.State, generation: UUID) {
        guard generation == listenerGeneration else { return }
        switch state {
        case .ready:
            boundPort = listener?.port.map { Int($0.rawValue) }
            lastError = nil
            webClientBridgeLog.info(
                "web client listener ready on \(self.bindAddress?.host ?? "unknown", privacy: .public):\(self.boundPort ?? 0)"
            )
            drainReadinessWaiters(.ok(statusPayload()))
        case .failed(let error):
            lastError = error.localizedDescription
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            bindAddress = nil
            requestedPort = nil
            boundPort = nil
            drainReadinessWaiters(.failure(MobileHostRPCError(
                code: "bind_failed",
                message: String(
                    localized: "webClientBridge.error.bindFailed",
                    defaultValue: "Unable to bind the web client listener."
                )
            )))
        case .cancelled:
            listener = nil
            bindAddress = nil
            requestedPort = nil
            boundPort = nil
            drainReadinessWaiters(.ok(statusPayload()))
        default:
            break
        }
    }

    private func waitForReadiness() async -> MobileHostRPCResult {
        await withCheckedContinuation { continuation in
            readinessWaiters.append(continuation)
            readinessTimeoutTask?.cancel()
            let readinessSleep = self.readinessSleep
            readinessTimeoutTask = Task { [weak self, readinessSleep] in
                try? await readinessSleep()
                guard !Task.isCancelled else { return }
                await self?.failReadinessTimeout()
            }
        }
    }

    private func failReadinessTimeout() {
        listenerGeneration = UUID()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        bindAddress = nil
        requestedPort = nil
        boundPort = nil
        lastError = String(
            localized: "webClientBridge.error.bindTimeout",
            defaultValue: "Web client listener did not become ready."
        )
        drainReadinessWaiters(
            .failure(MobileHostRPCError(
                code: "bind_timeout",
                message: String(
                    localized: "webClientBridge.error.bindTimeout",
                    defaultValue: "Web client listener did not become ready."
                )
            ))
        )
    }

    private func drainReadinessWaiters(_ result: MobileHostRPCResult) {
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = nil
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }

    private func statusPayload() -> [String: Any] {
        [
            "running": listener != nil && boundPort != nil,
            "address": bindAddress?.host ?? NSNull(),
            "port": boundPort ?? NSNull(),
            "protocol": Self.protocolIdentifier,
            "protocol_version": WebClientWebSocketTransport.protocolVersion,
            "pending_handshakes": pendingHandshakeTasks.count,
            "last_error": lastError ?? NSNull(),
        ]
    }

    private func statusPayloadWithGrants() async -> [String: Any] {
        var payload = statusPayload()
        let grants = await grantsPayload()
        payload["grants"] = grants["grants"] ?? []
        return payload
    }

    private func grantsPayload() async -> [String: Any] {
        let snapshots = await grantStore.snapshots()
        let counts = MobileHostConnectionRegistry.shared.webGrantConnectionCounts()
        return [
            "protocol": Self.protocolIdentifier,
            "protocol_version": WebClientWebSocketTransport.protocolVersion,
            "grants": snapshots.map { snapshot in
                Self.grantPayload(
                    snapshot,
                    connectionCount: counts[snapshot.id] ?? 0
                )
            },
        ]
    }

    private static func grantPayload(
        _ snapshot: WebClientGrantSnapshot,
        connectionCount: Int
    ) -> [String: Any] {
        [
            "id": snapshot.id.uuidString,
            "label": snapshot.label,
            "created_at": snapshot.createdAt.timeIntervalSince1970,
            "last_used_at": snapshot.lastUsedAt?.timeIntervalSince1970 ?? NSNull(),
            "revoked_at": snapshot.revokedAt?.timeIntervalSince1970 ?? NSNull(),
            "active": snapshot.isActive,
            "connection_count": connectionCount,
        ]
    }

    private static func makeListener(
        address: WebClientBridgeBindAddress,
        port: Int,
        requestQueue: DispatchQueue
    ) throws -> NWListener {
        // The direct listener is intentionally plaintext: loopback is local,
        // and Tailscale binds are encrypted by WireGuard. A browser served
        // from an HTTPS origin must put an explicit private TLS proxy (for
        // example tailscale serve) in front and use its wss:// endpoint;
        // cmux never opens a public wildcard/TLS listener implicitly.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let websocketOptions = NWProtocolWebSocket.Options()
        websocketOptions.autoReplyPing = true
        websocketOptions.maximumMessageSize = WebClientWebSocketTransport.maximumClientMessageByteCount
        let originPolicy = WebClientBridgeOriginPolicy(bindAddress: address)
        websocketOptions.setClientRequestHandler(requestQueue) { subprotocols, headers in
            let requestedSubprotocol = WebClientWebSocketTransport.webSocketSubprotocol
            let origin = headers.first {
                $0.name.caseInsensitiveCompare("Origin") == .orderedSame
            }?.value
            guard subprotocols.contains(requestedSubprotocol),
                  originPolicy.allows(originHeader: origin) else {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(
                status: .accept,
                subprotocol: requestedSubprotocol
            )
        }
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        // A stop/start or address change should be able to reclaim the same
        // explicit port immediately after the prior listener is cancelled.
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocketOptions, at: 0)
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            // Port zero is valid for an OS-assigned ephemeral listener.
            guard port == 0 else { throw WebClientBridgeBindAddress.ValidationError.unsupported }
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(address.host),
                port: .any
            )
            return try NWListener(using: parameters, on: .any)
        }
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(address.host),
            port: endpointPort
        )
        return try NWListener(using: parameters, on: endpointPort)
    }
}
