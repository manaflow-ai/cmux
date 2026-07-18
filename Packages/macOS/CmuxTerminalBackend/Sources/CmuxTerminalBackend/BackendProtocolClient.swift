internal import Foundation

/// Correlates command responses with a bounded stream of interleaved events.
/// A local event-buffer overflow closes the connection, forcing an atomic
/// resnapshot instead of allowing the UI to continue from a hidden gap.
public actor BackendProtocolClient {
    /// The maximum number of server events buffered before the connection closes.
    public static let defaultEventCapacity = 256

    /// Commands whose wire contract is observational. Read-only compatibility
    /// denies every command not named here, so new mutations fail closed until
    /// they are classified deliberately.
    private static let readOnlyCommands: Set<String> = [
        "identify",
        "list-presentations",
        "list-projection-states",
        "list-workspaces",
        "ping",
        "process-info",
        "read-screen",
        "renderer-workers",
        "subscribe-topology",
        "terminal-accessibility-activate-link",
        "terminal-accessibility-snapshot",
        "terminal-activity-snapshot",
        "terminal-request-status",
        "terminal-state",
        "topology-snapshot",
    ]

    private let transport: any BackendMessageTransport
    private let eventCapacity: Int
    private let eventStream: AsyncThrowingStream<BackendServerEvent, any Error>
    private let eventContinuation: AsyncThrowingStream<BackendServerEvent, any Error>.Continuation
    private var pending: [UInt64: CheckedContinuation<Data, any Error>] = [:]
    private var nextRequestID: UInt64 = 1
    private var receiveTask: Task<Void, Never>?
    private var connected = false
    private var finished = false
    private var compatibility: BackendCompatibilityResult?

    /// Creates a protocol client over a message transport.
    ///
    /// - Parameters:
    ///   - transport: The full-duplex transport carrying protocol messages.
    ///   - eventCapacity: The maximum number of buffered server events. This
    ///     value must be greater than zero.
    public init(
        transport: any BackendMessageTransport,
        eventCapacity: Int = BackendProtocolClient.defaultEventCapacity
    ) {
        precondition(eventCapacity > 0)
        self.transport = transport
        self.eventCapacity = eventCapacity
        let pair = AsyncThrowingStream<BackendServerEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(eventCapacity)
        )
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    /// Connects the transport and starts receiving responses and events.
    ///
    /// - Throws: ``BackendProtocolError/alreadyConnected`` when already
    ///   connected, ``BackendProtocolError/connectionClosed`` after the client
    ///   has finished, or a transport connection error.
    public func connect() async throws {
        guard !connected else { throw BackendProtocolError.alreadyConnected }
        guard !finished else { throw BackendProtocolError.connectionClosed }
        try await transport.connect()
        connected = true
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    /// Returns the bounded stream of server-pushed events.
    ///
    /// - Returns: The event stream shared by this client.
    public func events() -> AsyncThrowingStream<BackendServerEvent, any Error> {
        eventStream
    }

    /// Installs the result of the identify-first compatibility handshake.
    ///
    /// A direct protocol client remains unconstrained until its owner performs
    /// identification. Canonical production sessions call this exactly once
    /// before any post-identify command.
    public func installCompatibility(_ result: BackendCompatibilityResult) throws {
        if let compatibility {
            guard compatibility == result else { throw BackendProtocolError.malformedMessage }
            return
        }
        compatibility = result
    }

    /// Closes the transport and finishes pending requests and the event stream.
    public func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        connected = false
        await transport.close()
        finish(with: CancellationError())
    }

    /// Identifies the backend and its supported protocol capabilities.
    ///
    /// - Returns: The backend identity response.
    /// - Throws: A transport, decoding, or backend protocol error.
    public func identify() async throws -> BackendIdentifyResponse {
        try await call(command: "identify", as: BackendIdentifyResponse.self)
    }

    /// Fetches a lightweight process, authority, and structural-revision proof.
    ///
    /// - Returns: Health metadata without canonical topology contents.
    /// - Throws: A transport, decoding, or backend protocol error.
    public func health() async throws -> BackendHealthResponse {
        try await call(command: "ping", as: BackendHealthResponse.self)
    }

    /// Fetches an atomic snapshot of the canonical topology.
    ///
    /// - Returns: The current topology snapshot.
    /// - Throws: A transport, decoding, or backend protocol error.
    public func topologySnapshot() async throws -> TopologySnapshot {
        try await call(command: "topology-snapshot", as: TopologySnapshot.self)
    }

    /// Subscribes to topology changes after a known authority revision.
    ///
    /// - Parameters:
    ///   - authority: The daemon and session authority of the known snapshot.
    ///   - revision: The last topology revision the caller applied.
    /// - Returns: A subscription acknowledgement or a resnapshot requirement.
    /// - Throws: A transport, decoding, or backend protocol error.
    public func subscribeTopology(
        authority: BackendAuthority,
        revision: UInt64
    ) async throws -> TopologySubscriptionResponse {
        try await call(
            command: "subscribe-topology",
            parameters: [
                "daemon_instance_id": .string(authority.daemonInstanceID.description),
                "session_id": .string(authority.sessionID.description),
                "revision": .unsignedInteger(revision),
            ],
            as: TopologySubscriptionResponse.self
        )
    }

    /// Registers a presentation for a client-visible terminal view.
    ///
    /// - Parameters:
    ///   - view: The entities visible in the presentation.
    ///   - zoom: The pane zoom state.
    ///   - scroll: The terminal scroll state.
    /// - Returns: The registered presentation and its initial generation.
    /// - Throws: A transport, decoding, or backend protocol error.
    public func openPresentation(
        view: BackendPresentationView = BackendPresentationView(),
        zoom: BackendPresentationZoom = BackendPresentationZoom(),
        scroll: BackendPresentationScroll = BackendPresentationScroll()
    ) async throws -> BackendPresentation {
        try await call(
            command: "open-presentation",
            parameters: [
                "view": view.jsonValue,
                "zoom": zoom.jsonValue,
                "scroll": scroll.jsonValue,
            ],
            as: BackendPresentation.self
        )
    }

    /// Activates one terminal presentation for leased input and geometry.
    ///
    /// This command does not configure or start a renderer worker.
    ///
    /// - Parameters:
    ///   - id: The connection-owned presentation to activate.
    ///   - expectedGeneration: The exact generation returned when it opened.
    /// - Returns: The daemon's exact presentation and PTY surface proof.
    /// - Throws: A transport, decoding, identity, or backend protocol error.
    public func activateTerminalPresentation(
        id: PresentationID,
        expectedGeneration: UInt64
    ) async throws -> BackendTerminalPresentationActivation {
        try await call(
            command: "activate-terminal-presentation",
            parameters: [
                "presentation_id": .string(id.description),
                "expected_generation": .unsignedInteger(expectedGeneration),
            ],
            as: BackendTerminalPresentationActivation.self
        )
    }

    /// Atomically updates a presentation when its generation still matches.
    ///
    /// - Parameters:
    ///   - id: The presentation to update.
    ///   - expectedGeneration: The generation the caller most recently observed.
    ///   - view: A replacement view, or `nil` to retain the current view.
    ///   - zoom: A replacement zoom state, or `nil` to retain the current state.
    ///   - scroll: A replacement scroll state, or `nil` to retain the current state.
    /// - Returns: The updated presentation and its new generation.
    /// - Throws: A transport, decoding, or backend protocol error.
    public func updatePresentation(
        id: PresentationID,
        expectedGeneration: UInt64,
        view: BackendPresentationView? = nil,
        zoom: BackendPresentationZoom? = nil,
        scroll: BackendPresentationScroll? = nil
    ) async throws -> BackendPresentation {
        var parameters: [String: BackendJSONValue] = [
            "presentation_id": .string(id.description),
            "expected_generation": .unsignedInteger(expectedGeneration),
        ]
        if let view { parameters["view"] = view.jsonValue }
        if let zoom { parameters["zoom"] = zoom.jsonValue }
        if let scroll { parameters["scroll"] = scroll.jsonValue }
        return try await call(
            command: "update-presentation",
            parameters: parameters,
            as: BackendPresentation.self
        )
    }

    /// Removes a presentation from the backend registry.
    ///
    /// - Parameter id: The presentation to remove.
    /// - Throws: A transport, decoding, or backend protocol error.
    public func closePresentation(id: PresentationID) async throws {
        let _: BackendEmptyResponse = try await call(
            command: "close-presentation",
            parameters: ["presentation_id": .string(id.description)],
            as: BackendEmptyResponse.self
        )
    }

    /// Lists the presentations currently registered with the backend.
    ///
    /// - Returns: The registered presentations.
    /// - Throws: A transport, decoding, or backend protocol error.
    public func listPresentations() async throws -> [BackendPresentation] {
        try await call(command: "list-presentations", as: [BackendPresentation].self)
    }

    /// Sends a command and decodes its correlated response payload.
    ///
    /// - Parameters:
    ///   - command: The backend command name.
    ///   - parameters: Command-specific wire fields.
    ///   - as: The response payload type.
    /// - Returns: The decoded response payload.
    /// - Throws: A transport, encoding, decoding, or backend protocol error.
    public func call<Payload: Decodable & Sendable>(
        command: String,
        parameters: [String: BackendJSONValue] = [:],
        as _: Payload.Type = Payload.self
    ) async throws -> Payload {
        try Task.checkCancellation()
        guard connected, !finished else { throw BackendProtocolError.notConnected }
        try authorize(command: command, parameters: parameters)
        guard nextRequestID != UInt64.max else {
            throw BackendProtocolError.requestIDExhausted
        }
        let id = nextRequestID
        nextRequestID += 1
        let encoded = try JSONEncoder().encode(
            BackendWireRequest(id: id, command: command, parameters: parameters)
        )

        let responseData = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task { [weak self] in
                    await self?.send(encoded, requestID: id)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelAndClose(requestID: id)
            }
        }
        try Task.checkCancellation()

        let response = try JSONDecoder().decode(
            BackendResponseEnvelope<Payload>.self,
            from: responseData
        )
        try Task.checkCancellation()
        guard response.ok else {
            throw BackendProtocolError.server(response.error ?? "unknown backend error")
        }
        guard let payload = response.data else {
            throw BackendProtocolError.malformedMessage
        }
        return payload
    }

    private func authorize(
        command: String,
        parameters: [String: BackendJSONValue]
    ) throws {
        guard case .readOnly(let diagnostic) = compatibility else { return }
        let selectionRead = command == "terminal-selection"
            && parameters["operation"] == .string("read")
        guard Self.readOnlyCommands.contains(command) || selectionRead else {
            throw BackendProtocolError.mutationUnavailableInReadOnlyMode(
                command: command,
                compatibility: diagnostic
            )
        }
    }

    private func send(_ data: Data, requestID: UInt64) async {
        guard pending[requestID] != nil else { return }
        do {
            try await transport.send(data)
        } catch {
            pending.removeValue(forKey: requestID)?.resume(throwing: error)
            receiveTask?.cancel()
            receiveTask = nil
            connected = false
            await transport.close()
            finish(with: error)
        }
    }

    /// The protocol has no request-cancellation acknowledgement. Closing is
    /// safer than keeping a connection on which a late response can be
    /// mistaken for an unknown request or silently consume an ID forever.
    private func cancelAndClose(requestID: UInt64) async {
        pending.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
        guard connected else { return }
        receiveTask?.cancel()
        receiveTask = nil
        connected = false
        await transport.close()
        finish(with: CancellationError())
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let data = try await transport.receive()
                let header = try JSONDecoder().decode(BackendInboundHeader.self, from: data)
                if header.event != nil {
                    guard header.id == nil, header.ok == nil, header.error == nil else {
                        throw BackendProtocolError.malformedMessage
                    }
                    let event = try JSONDecoder().decode(BackendServerEvent.self, from: data)
                    switch eventContinuation.yield(event) {
                    case .enqueued:
                        break
                    case .dropped:
                        throw BackendProtocolError.eventBufferOverflow(capacity: eventCapacity)
                    case .terminated:
                        throw BackendProtocolError.connectionClosed
                    @unknown default:
                        throw BackendProtocolError.connectionClosed
                    }
                } else if let id = header.id {
                    guard let continuation = pending.removeValue(forKey: id) else {
                        throw BackendProtocolError.malformedMessage
                    }
                    continuation.resume(returning: data)
                } else if header.ok == false {
                    throw BackendProtocolError.server(header.error ?? "uncorrelated backend error")
                } else {
                    throw BackendProtocolError.malformedMessage
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            connected = false
            await transport.close()
            finish(with: error)
        }
    }

    private func finish(with error: any Error) {
        guard !finished else { return }
        finished = true
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
        eventContinuation.finish(throwing: error)
    }
}
