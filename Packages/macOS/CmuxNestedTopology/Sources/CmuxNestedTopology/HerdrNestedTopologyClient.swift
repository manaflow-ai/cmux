import Foundation

/// Herdr nested topology client over the local newline-delimited JSON Unix socket API.
///
/// This client never shells out to the `herdr` CLI. It performs handshake (`ping`),
/// `session.snapshot`, `events.subscribe`, and capability-gated `*.focus` RPCs.
/// Reconnects always assign a new provider instance generation (until Herdr returns
/// a durable `instance_id`) and invalidate association entries from prior generations.
/// Unavailable methods fail closed — never synthesized via keystrokes or shell.
public actor HerdrNestedTopologyClient: NestedTopologyProviderClient {
    private let configuration: HerdrNestedTopologyClientConfiguration
    private let compatibility: HerdrProtocol17Compatibility
    private let reconnectScheduler: any NestedReconnectScheduler
    private var associations: NestedAssociationStore
    private var latestHandshake: NestedProviderHandshake?
    private var handshakeTask: Task<NestedProviderHandshake, any Error>?

    /// Creates a Herdr nested topology client.
    ///
    /// - Parameters:
    ///   - configuration: Socket path, host attachment identity, and transport bounds.
    ///   - associations: Optional in-memory association store invalidated across generations.
    ///   - compatibility: Protocol-17 adapter used for decode/mapping.
    ///   - reconnectScheduler: Cancellation-aware backoff used between reconnect attempts.
    public init(
        configuration: HerdrNestedTopologyClientConfiguration,
        associations: NestedAssociationStore = NestedAssociationStore(),
        compatibility: HerdrProtocol17Compatibility = HerdrProtocol17Compatibility(),
        reconnectScheduler: any NestedReconnectScheduler = NestedContinuousClockReconnectScheduler()
    ) {
        self.configuration = configuration
        self.associations = associations
        self.compatibility = compatibility
        self.reconnectScheduler = reconnectScheduler
    }

    /// Current association store snapshot.
    public func associationStore() -> NestedAssociationStore {
        associations
    }

    /// Replaces the association store (tests / coordinator wiring).
    public func setAssociationStore(_ store: NestedAssociationStore) {
        associations = store
    }

    /// Latest successful handshake for this actor, if any.
    public func currentHandshake() -> NestedProviderHandshake? {
        latestHandshake
    }

    public func handshake() async throws -> NestedProviderHandshake {
        if let handshakeTask {
            return try await handshakeTask.value
        }
        let task = Task { try await self.performHandshake() }
        handshakeTask = task
        defer { handshakeTask = nil }
        return try await task.value
    }

    private func performHandshake() async throws -> NestedProviderHandshake {
        let response = try await performRequest(method: "ping", params: [:])
        guard let result = response.result, case .pong(let pong) = result else {
            throw NestedTopologyProviderError.missingRequiredField("result.type=pong")
        }

        // Gap: protocol 17 does not yet advertise a durable server instance_id.
        // Prefer the provider value when present; otherwise mint a connection generation.
        // Minted generations are not durable identity proof for unattended restore.
        let instanceID: NestedProviderInstanceID
        let instanceIdentityIsDurable: Bool
        if let raw = pong.instanceID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            instanceID = NestedProviderInstanceID(rawValue: raw)
            instanceIdentityIsDurable = true
        } else {
            instanceID = .randomConnectionGeneration()
            instanceIdentityIsDurable = false
        }

        let handshake = try compatibility.makeHandshake(
            from: pong,
            providerInstanceID: instanceID,
            instanceIdentityIsDurable: instanceIdentityIsDurable
        )
        associations.invalidate(providerInstanceGeneration: handshake.providerInstanceID)
        latestHandshake = handshake
        return handshake
    }

    public func snapshot() async throws -> NestedTopologySnapshot {
        try await snapshotWithLayouts().snapshot
    }

    /// Snapshot plus Herdr layout trees keyed by tab id (PR7 window mirror).
    public func snapshotWithLayouts() async throws -> (
        snapshot: NestedTopologySnapshot,
        layouts: [String: RemoteHerdrLayoutNode]
    ) {
        let handshake = try await ensureHandshake()
        let response = try await performRequest(method: "session.snapshot", params: [:])
        guard let result = response.result, case .sessionSnapshot(let wire) = result else {
            throw NestedTopologyProviderError.missingRequiredField("result.type=session_snapshot")
        }
        if wire.protocolNumber != HerdrProtocol17Compatibility.supportedProtocolNumber {
            throw NestedTopologyProviderError.unsupportedProtocol(wire.protocolNumber)
        }
        let snapshot = try compatibility.makeSnapshot(
            from: wire,
            handshake: handshake,
            attachmentID: configuration.attachmentID,
            hostStableSurfaceID: configuration.hostStableSurfaceID,
            limits: configuration.topologyLimits
        )
        return (snapshot, wire.layouts)
    }

    public nonisolated func events() -> AsyncThrowingStream<NestedTopologyEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runEventLoop(continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func focus(nodeID: NestedNodeID) async throws {
        let handshake = try await ensureHandshake()
        guard handshake.capabilities.contains(.topologyFocusV1) else {
            throw NestedTopologyProviderError.providerError(
                code: "capability_absent",
                message: NestedProviderCapability.topologyFocusV1.rawValue
            )
        }
        guard nodeID.providerKind == .herdr else {
            throw NestedTopologyProviderError.providerError(
                code: "wrong_kind",
                message: "focus requires herdr provider kind"
            )
        }
        guard nodeID.providerInstanceID == handshake.providerInstanceID else {
            throw NestedTopologyProviderError.providerError(
                code: "stale_instance",
                message: "node provider instance does not match live handshake"
            )
        }

        let method: String
        let params: [String: Any]
        switch nodeID.kind {
        case .workspace:
            method = "workspace.focus"
            params = ["workspace_id": nodeID.rawID]
        case .tab:
            method = "tab.focus"
            params = ["tab_id": nodeID.rawID]
        case .pane:
            method = "pane.focus"
            params = ["pane_id": nodeID.rawID]
        case .agent:
            // Herdr agents are addressed by pane id (`AgentTarget.target`).
            method = "agent.focus"
            params = ["target": nodeID.rawID]
        }

        let response = try await performRequest(method: method, params: params)
        guard response.result != nil else {
            throw NestedTopologyProviderError.missingRequiredField("result")
        }
        // Success shapes vary (`workspace_info`, `tab_info`, `pane_info`, …).
        // Topology is reconciled from events / resnapshot — do not invent focus.
    }

    // MARK: - Event loop

    private func runEventLoop(
        continuation: AsyncThrowingStream<NestedTopologyEvent, any Error>.Continuation
    ) async {
        var backoff = configuration.reconnectInitialBackoff
        var isFirstAttempt = true

        while !Task.isCancelled {
            do {
                if !isFirstAttempt {
                    // Mandatory full resnapshot on every reconnect.
                    _ = try await handshake()
                } else {
                    _ = try await ensureHandshake()
                }
                // One required snapshot per attempt: drives pane-scoped subscriptions and
                // (on reconnect) the authoritative replaceSnapshot. Fail closed — never
                // subscribe with an empty pane set after a silent snapshot failure.
                let snap = try await snapshot()
                let paneIDs = snap.panes.map(\.id.rawID)
                if !isFirstAttempt {
                    continuation.yield(.replaceSnapshot(snap))
                }
                isFirstAttempt = false
                backoff = configuration.reconnectInitialBackoff
                try await subscribeAndForward(
                    continuation: continuation,
                    paneIDs: paneIDs
                )
                throw NestedTopologyProviderError.unexpectedEOF
            } catch is CancellationError {
                continuation.finish(throwing: NestedTopologyProviderError.cancelled)
                return
            } catch let error as NestedTopologyProviderError {
                switch error {
                case .cancelled, .unsupportedProtocol:
                    continuation.finish(throwing: error)
                    return
                case .connectTimeout, .requestTimeout, .unexpectedEOF, .oversizedLine,
                     .oversizedSnapshot, .oversizedEvent, .invalidUTF8, .malformedJSON,
                     .responseIDMismatch, .providerError, .missingRequiredField, .transport:
                    break
                }
                if Task.isCancelled {
                    continuation.finish(throwing: NestedTopologyProviderError.cancelled)
                    return
                }
                do {
                    try await reconnectScheduler.waitForReconnectAttempt(after: backoff)
                } catch {
                    continuation.finish(throwing: NestedTopologyProviderError.cancelled)
                    return
                }
                backoff = doubledBackoff(backoff)
            } catch {
                if Task.isCancelled {
                    continuation.finish(throwing: NestedTopologyProviderError.cancelled)
                    return
                }
                do {
                    try await reconnectScheduler.waitForReconnectAttempt(after: backoff)
                } catch {
                    continuation.finish(throwing: NestedTopologyProviderError.cancelled)
                    return
                }
                backoff = doubledBackoff(backoff)
            }
        }
        continuation.finish(throwing: NestedTopologyProviderError.cancelled)
    }

    private func subscribeAndForward(
        continuation: AsyncThrowingStream<NestedTopologyEvent, any Error>.Continuation,
        paneIDs: [String]
    ) async throws {
        let handshake = try await ensureHandshake()
        // Parameterized status events require pane_id; subscribe for panes from the
        // snapshot already taken by runEventLoop (no second session.snapshot here).
        let normalizedPaneIDs = paneIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let subscriptions = HerdrProtocol17Compatibility.subscriptions(
            forPaneIDs: normalizedPaneIDs
        )
        let requestID = HerdrJSONRPCRequestID.random(prefix: "cmux-sub")
        let requestObject: [String: Any] = [
            "id": requestID.rawValue,
            "method": "events.subscribe",
            "params": [
                "subscriptions": subscriptions,
            ],
        ]
        let requestData = try Self.encodeJSONObject(requestObject)
        if requestData.count > configuration.maxLineUTF8ByteCount {
            throw NestedTopologyProviderError.oversizedLine(
                maxUTF8ByteCount: configuration.maxLineUTF8ByteCount
            )
        }

        let compatibility = self.compatibility
        let maxLine = configuration.maxLineUTF8ByteCount
        let maxEvent = configuration.maxEventUTF8ByteCount
        let connectTimeout = configuration.connectTimeout
        let idleTimeout = configuration.eventIdleTimeout
        let socketPath = configuration.socketPath
        let initialPaneIDs = normalizedPaneIDs

        let connection = try HerdrUnixSocketConnection(path: socketPath, timeout: connectTimeout)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                Thread.detachNewThread {
                    var finished = false
                    let finish: (Result<Void, any Error>) -> Void = { result in
                        guard !finished else { return }
                        finished = true
                        connection.close()
                        cont.resume(with: result)
                    }
                    var subscribedPaneIDs = Set(initialPaneIDs)

                    do {
                        try connection.writeAll(requestData + Data([UInt8(ascii: "\n")]))
                        var reader = HerdrJSONLineReader(maxLineUTF8ByteCount: maxLine)
                        var acknowledged = false
                        let clock = ContinuousClock()
                        var lastActivity = clock.now
                        while !Task.isCancelled {
                            let chunk: Data
                            do {
                                chunk = try connection.readSome(
                                    maxLength: min(64 * 1024, maxLine),
                                    timeout: .seconds(1)
                                )
                            } catch NestedTopologyProviderError.requestTimeout {
                                // Poll slice timed out; keep waiting until the idle bound elapses.
                                if clock.now - lastActivity >= idleTimeout {
                                    throw NestedTopologyProviderError.requestTimeout
                                }
                                continue
                            }
                            lastActivity = clock.now
                            let lines = try reader.append(chunk)
                            for line in lines {
                                if acknowledged, line.utf8.count > maxEvent {
                                    throw NestedTopologyProviderError.oversizedEvent(
                                        maxUTF8ByteCount: maxEvent
                                    )
                                }
                                if !acknowledged {
                                    let response = try compatibility.decodeResponseLine(
                                        line,
                                        expectedRequestID: requestID
                                    )
                                    guard let subResult = response.result,
                                          case .subscriptionStarted = subResult
                                    else {
                                        throw NestedTopologyProviderError.missingRequiredField(
                                            "result.type=subscription_started"
                                        )
                                    }
                                    acknowledged = true
                                    continue
                                }
                                let envelope = try compatibility.decodeEventLine(line)
                                let events = try compatibility.mapEvent(
                                    envelope,
                                    handshake: handshake
                                )
                                for event in events {
                                    continuation.yield(event)
                                    // pane.agent_status_changed is subscribed per pane_id at
                                    // connect time. A newly upserted pane is not covered until
                                    // we reconnect and resubscribe from a fresh snapshot.
                                    if case let .paneUpserted(pane) = event {
                                        let rawID = pane.id.rawID.trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        )
                                        if !rawID.isEmpty, !subscribedPaneIDs.contains(rawID) {
                                            throw NestedTopologyProviderError.unexpectedEOF
                                        }
                                    }
                                }
                            }
                        }
                        throw NestedTopologyProviderError.cancelled
                    } catch {
                        finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            connection.close()
        }
    }

    // MARK: - Request helper

    private func ensureHandshake() async throws -> NestedProviderHandshake {
        if let latestHandshake {
            return latestHandshake
        }
        return try await handshake()
    }

    func performRequest(
        method: String,
        params: [String: Any]
    ) async throws -> HerdrWireResponse {
        let requestID = HerdrJSONRPCRequestID.random(prefix: "cmux")
        let requestObject: [String: Any] = [
            "id": requestID.rawValue,
            "method": method,
            "params": params,
        ]
        let requestData = try Self.encodeJSONObject(requestObject)
        if requestData.count > configuration.maxLineUTF8ByteCount {
            throw NestedTopologyProviderError.oversizedLine(
                maxUTF8ByteCount: configuration.maxLineUTF8ByteCount
            )
        }

        let compatibility = self.compatibility
        let maxLine = configuration.maxLineUTF8ByteCount
        let maxSnapshot = configuration.maxSnapshotUTF8ByteCount
        let connectTimeout = configuration.connectTimeout
        let requestTimeout = configuration.requestTimeout
        let socketPath = configuration.socketPath

        let connection = try HerdrUnixSocketConnection(path: socketPath, timeout: connectTimeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HerdrWireResponse, Error>) in
                Thread.detachNewThread {
                    var finished = false
                    let finish: (Result<HerdrWireResponse, any Error>) -> Void = { result in
                        guard !finished else { return }
                        finished = true
                        connection.close()
                        cont.resume(with: result)
                    }
                    do {
                        try connection.writeAll(requestData + Data([UInt8(ascii: "\n")]))
                        var reader = HerdrJSONLineReader(maxLineUTF8ByteCount: maxLine)
                        let clock = ContinuousClock()
                        let deadline = clock.now.advanced(by: requestTimeout)
                        while clock.now < deadline {
                            if Task.isCancelled {
                                throw NestedTopologyProviderError.cancelled
                            }
                            let remaining = deadline - clock.now
                            let timeout = remaining < Duration.milliseconds(1)
                                ? Duration.milliseconds(1)
                                : remaining
                            let chunk = try connection.readSome(
                                maxLength: min(64 * 1024, maxLine),
                                timeout: timeout
                            )
                            let lines = try reader.append(chunk)
                            if let line = lines.first {
                                if method == "session.snapshot",
                                   line.utf8.count > maxSnapshot
                                {
                                    throw NestedTopologyProviderError.oversizedSnapshot(
                                        maxUTF8ByteCount: maxSnapshot
                                    )
                                }
                                let response = try compatibility.decodeResponseLine(
                                    line,
                                    expectedRequestID: requestID
                                )
                                finish(.success(response))
                                return
                            }
                        }
                        throw NestedTopologyProviderError.requestTimeout
                    } catch {
                        finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            connection.close()
        }
    }

    private func doubledBackoff(_ backoff: Duration) -> Duration {
        let doubled = backoff + backoff
        return doubled > configuration.reconnectMaxBackoff
            ? configuration.reconnectMaxBackoff
            : doubled
    }

    private static func encodeJSONObject(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw NestedTopologyProviderError.malformedJSON("request is not a valid JSON object")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }
}
