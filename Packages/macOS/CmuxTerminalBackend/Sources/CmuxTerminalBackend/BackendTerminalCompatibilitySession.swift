internal import Foundation

/// One exact-peer, protocol-v9 connection dedicated to one mobile terminal lane.
///
/// It never subscribes to canonical topology events. A one-time topology
/// snapshot resolves the stable surface UUID to the daemon-local attach handle;
/// all later output is the capability-scoped compatibility stream on this
/// connection. Any malformed, stale, gapped, or locally dropped frame closes
/// only this session.
public actor BackendTerminalCompatibilitySession {
    public static let capability = "terminal-byte-stream-compat-v1"
    public static let defaultEventCapacity = 16
    /// Five MiB remains below the mobile RPC protocol's eight-MiB frame after
    /// base64 expansion and JSON envelope overhead.
    public static let maximumReplayBytes = 5 * 1_024 * 1_024
    public static let maximumOutputBytes = 1 * 1_024 * 1_024
    public static let maximumInputBytes = 16 * 1_024

    private static let handshakePolicy = BackendHandshakePolicy(
        supportedRange: 9 ... 9,
        minimumReadWriteProtocol: 9,
        requiredCapabilities: Set([
            capability,
            "canonical-topology-snapshot-v1",
            "stable-entity-uuid-v1",
        ]).union(BackendHandshakePolicy.terminalControlV9Capabilities)
    )

    private struct ResolvedSurface: Sendable {
        let handle: UInt64
        let surfaceID: SurfaceID
    }

    private let transport: any BackendPeerIdentityTransport
    private let client: BackendProtocolClient
    private let expectation: BackendCanonicalSessionExpectation
    private let registrationIdentity: BackendClientRegistrationIdentity
    private let inputAuthority: any BackendTerminalCompatibilityInputAuthority
    private let eventCapacity: Int
    private let eventStream: AsyncThrowingStream<BackendTerminalCompatibilityEvent, any Error>
    private let eventContinuation:
        AsyncThrowingStream<BackendTerminalCompatibilityEvent, any Error>.Continuation

    private var eventTask: Task<Void, Never>?
    private var initialWaiters: [
        CheckedContinuation<BackendTerminalCompatibilitySnapshot, any Error>
    ] = []
    private var initialSnapshotValue: BackendTerminalCompatibilitySnapshot?
    private var resolvedSurface: ResolvedSurface?
    private var registration: BackendClientRegistration?
    private var inputDelegation: BackendTerminalInputDelegation?
    private var nextInputSequence: UInt64?
    private var inputOperationActive = false
    private var inputOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var attached = false
    private var eventsClaimed = false
    private var finished = false

    /// Creates one fail-closed compatibility connection for a single mobile lane.
    ///
    /// - Parameters:
    ///   - transport: A transport that exposes the authenticated daemon peer identity.
    ///   - expectation: The exact session, authority, process, and peer expected after connect.
    ///   - registrationIdentity: The unique logical client identity for this mobile lane.
    ///   - inputAuthority: The canonical frontend that grants text-only delegated input.
    ///   - eventCapacity: The bounded number of decoded compatibility events retained locally.
    public init(
        transport: any BackendPeerIdentityTransport,
        expectation: BackendCanonicalSessionExpectation,
        registrationIdentity: BackendClientRegistrationIdentity,
        inputAuthority: any BackendTerminalCompatibilityInputAuthority,
        eventCapacity: Int = BackendTerminalCompatibilitySession.defaultEventCapacity
    ) {
        precondition(eventCapacity > 0)
        self.transport = transport
        self.expectation = expectation
        self.registrationIdentity = registrationIdentity
        self.inputAuthority = inputAuthority
        self.eventCapacity = eventCapacity
        client = BackendProtocolClient(transport: transport, eventCapacity: eventCapacity)
        let pair = AsyncThrowingStream<BackendTerminalCompatibilityEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(eventCapacity)
        )
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    deinit {
        eventTask?.cancel()
    }

    /// Authenticates, registers, and attaches this dedicated connection.
    ///
    /// The raw event consumer is installed before `attach-surface` is sent,
    /// because cmuxd intentionally sends `vt-state` before the correlated
    /// command response.
    @discardableResult
    public func attach(
        surfaceID: SurfaceID
    ) async throws -> BackendTerminalCompatibilitySnapshot {
        guard !attached, eventTask == nil else {
            throw BackendTerminalCompatibilityError.alreadyAttached
        }
        guard !finished else { throw BackendProtocolError.connectionClosed }
        guard let expectedPeer = expectation.peerIdentity else {
            throw BackendTerminalCompatibilityError.missingExactPeerExpectation
        }

        do {
            try await client.connect()
            let actualPeer = try await transport.peerIdentity()
            guard actualPeer == expectedPeer else {
                throw BackendCanonicalSessionError.unexpectedPeerIdentity(
                    expected: expectedPeer,
                    actual: actualPeer
                )
            }

            let identify = try await client.identify()
            try validateIdentity(identify)
            let compatibility = try Self.handshakePolicy.validate(identify)
            guard case .readWrite(let readWrite) = compatibility,
                  readWrite.negotiatedProtocol == 9 else {
                throw BackendTerminalCompatibilityError.incompatibleBackend
            }
            try await client.installCompatibility(compatibility)

            let registration = try await client.registerClient(
                supportedRange: 9 ... 9,
                identity: registrationIdentity,
                kind: .mobileCompatibility
            )
            guard registration.protocolVersion == 9,
                  registration.clientUUID == registrationIdentity.clientUUID,
                  registration.processInstanceUUID == registrationIdentity.processInstanceUUID,
                  registration.clientKind == .mobileCompatibility,
                  registration.role == .trustedInputDelegate,
                  registration.topologyMutationLease == nil else {
                throw BackendTerminalControlError.registrationIdentityMismatch
            }
            self.registration = registration

            let topology = try await client.topologySnapshot()
            guard topology.authority == identify.authority else {
                throw BackendCanonicalSessionError.snapshotAuthorityMismatch(
                    expected: identify.authority,
                    actual: topology.authority
                )
            }
            let resolved = try resolve(surfaceID, in: topology.topology)
            resolvedSurface = resolved

            let rawEvents = await client.events()
            startEventTask(rawEvents)

            let _: BackendEmptyResponse = try await client.call(
                command: "attach-surface",
                parameters: [
                    "surface": .unsignedInteger(resolved.handle),
                    "mode": .string("compatibility"),
                    "replay_max_bytes": .unsignedInteger(
                        UInt64(Self.maximumReplayBytes)
                    ),
                ],
                as: BackendEmptyResponse.self
            )
            let initial = try await awaitInitialSnapshot()
            attached = true
            return initial
        } catch {
            await fail(error)
            throw error
        }
    }

    /// Returns the bounded, validated output stream for this one connection.
    public func events() throws -> AsyncThrowingStream<BackendTerminalCompatibilityEvent, any Error> {
        guard eventTask != nil, !finished else {
            throw BackendTerminalCompatibilityError.notAttached
        }
        guard !eventsClaimed else {
            throw BackendTerminalCompatibilityError.eventsAlreadyClaimed
        }
        eventsClaimed = true
        return eventStream
    }

    /// Sends mobile text through a text-only delegation from the canonical
    /// Swift input owner. Authorization is refreshed before every frame, so an
    /// implementation can replace an authority near its monotonic deadline
    /// without a timer. Any authority or receipt failure closes this dedicated
    /// lane instead of retrying an input with ambiguous PTY effects.
    public func sendInput(_ text: String) async throws {
        await beginInputOperation()
        defer { endInputOperation() }
        try Task.checkCancellation()
        guard attached, !finished, let resolvedSurface, registration != nil else {
            throw BackendTerminalCompatibilityError.notAttached
        }
        guard let data = text.data(using: .utf8), data.count <= Self.maximumInputBytes else {
            throw BackendTerminalCompatibilityError.inputTooLarge(
                maximumBytes: Self.maximumInputBytes
            )
        }
        guard !data.isEmpty else { return }

        do {
            let previous = inputDelegation
            let authorized = try await inputAuthority.authorizeTerminalCompatibilityInput(
                surfaceID: resolvedSurface.surfaceID,
                delegateIdentity: registrationIdentity,
                replacing: previous
            )
            guard !finished, attached else {
                try? await inputAuthority.revokeTerminalCompatibilityInput(
                    surfaceID: resolvedSurface.surfaceID,
                    delegateIdentity: registrationIdentity,
                    delegation: authorized
                )
                throw BackendProtocolError.connectionClosed
            }
            // Retain the exact returned authority before validation so a
            // malformed replacement is still revoked by the fail path.
            inputDelegation = authorized
            try validateInputDelegation(
                authorized,
                surfaceID: resolvedSurface.surfaceID
            )
            let sameAuthority = previous.map {
                $0.delegationID == authorized.delegationID
                    && $0.delegationGeneration == authorized.delegationGeneration
            } ?? false
            if sameAuthority {
                guard previous == authorized, nextInputSequence != nil else {
                    throw BackendProtocolError.malformedMessage
                }
            } else {
                nextInputSequence = authorized.nextSequence
            }
            guard let sequence = nextInputSequence else {
                throw BackendProtocolError.malformedMessage
            }

            let requestID = UUID()
            let receipt = try await client.sendDelegatedTerminalInput(
                delegation: authorized,
                sequence: sequence,
                requestID: requestID,
                input: .text(text, paste: false)
            )
            try validateInputReceipt(
                receipt,
                requestID: requestID,
                sequence: sequence,
                leaseGeneration: authorized.ownerLeaseGeneration,
                encodedBytes: UInt64(data.count)
            )
            guard try await client.acknowledgeTerminalRequest(
                surfaceID: resolvedSurface.surfaceID,
                requestID: requestID
            ) else {
                throw BackendProtocolError.malformedMessage
            }
            guard sequence < UInt64.max else {
                throw BackendProtocolError.malformedMessage
            }
            nextInputSequence = sequence + 1
        } catch {
            await fail(error)
            throw error
        }
    }

    /// Revokes this connection's exact delegation, then closes the transport.
    public func close() async {
        guard !finished else { return }
        finished = true
        eventTask?.cancel()
        eventTask = nil
        await revokeInputDelegationIfNeeded()
        await client.close()
        finishWaiters(throwing: CancellationError())
        eventContinuation.finish()
    }

    private func startEventTask(
        _ rawEvents: AsyncThrowingStream<BackendServerEvent, any Error>
    ) {
        eventTask = Task { [weak self] in
            do {
                for try await event in rawEvents {
                    try Task.checkCancellation()
                    try await self?.consume(event)
                }
                await self?.fail(BackendProtocolError.connectionClosed)
            } catch is CancellationError {
                // Explicit close owns teardown.
            } catch {
                await self?.fail(error)
            }
        }
    }

    private func consume(_ event: BackendServerEvent) async throws {
        guard let resolvedSurface else {
            throw BackendProtocolError.malformedMessage
        }
        let decoded: BackendTerminalCompatibilityEvent
        switch event.name {
        case "vt-state":
            guard initialSnapshotValue == nil else {
                throw BackendTerminalCompatibilityError.invalidEvent(event.name)
            }
            let snapshot = try decodeSnapshot(
                event,
                resolvedSurface: resolvedSurface,
                replayKey: "data"
            )
            guard string(event.fields["fidelity"])
                    == BackendTerminalCompatibilitySnapshot.fidelity else {
                throw BackendTerminalCompatibilityError.invalidEvent(event.name)
            }
            initialSnapshotValue = snapshot
            finishInitialWaiters(returning: snapshot)
            decoded = .snapshot(snapshot)

        case "output":
            let current = try currentSnapshot(for: event.name)
            let identity = try decodeIdentity(event, resolvedSurface: resolvedSurface)
            let start = try unsigned(event.fields["start_sequence"])
            let next = try unsigned(event.fields["next_sequence"])
            let data = try decodedBase64(event.fields["data"], maximumBytes: Self.maximumOutputBytes)
            guard identity.runtimeEpoch == current.runtimeEpoch,
                  identity.generation == current.generation,
                  start == current.sequence,
                  next >= start,
                  next - start == UInt64(data.count) else {
                throw BackendTerminalCompatibilityError.invalidEvent(event.name)
            }
            let output = BackendTerminalCompatibilityOutput(
                surfaceID: resolvedSurface.surfaceID,
                runtimeEpoch: identity.runtimeEpoch,
                generation: identity.generation,
                startSequence: start,
                nextSequence: next,
                data: data
            )
            initialSnapshotValue = BackendTerminalCompatibilitySnapshot(
                surfaceID: current.surfaceID,
                runtimeEpoch: current.runtimeEpoch,
                generation: current.generation,
                sequence: next,
                columns: current.columns,
                rows: current.rows,
                replay: current.replay
            )
            decoded = .output(output)

        case "resized":
            let current = try currentSnapshot(for: event.name)
            let replacement = try decodeSnapshot(
                event,
                resolvedSurface: resolvedSurface,
                replayKey: "replay"
            )
            guard replacement.runtimeEpoch == current.runtimeEpoch,
                  replacement.generation == current.generation + 1,
                  replacement.sequence == current.sequence else {
                throw BackendTerminalCompatibilityError.invalidEvent(event.name)
            }
            initialSnapshotValue = replacement
            decoded = .replacement(replacement)

        case "colors-changed":
            let current = try currentSnapshot(for: event.name)
            let identity = try decodeIdentity(event, resolvedSurface: resolvedSurface)
            let sequence = try unsigned(event.fields["sequence"])
            guard identity.runtimeEpoch == current.runtimeEpoch,
                  identity.generation == current.generation,
                  sequence == current.sequence else {
                throw BackendTerminalCompatibilityError.invalidEvent(event.name)
            }
            decoded = .colorsChanged(BackendTerminalCompatibilityColors(
                surfaceID: resolvedSurface.surfaceID,
                runtimeEpoch: identity.runtimeEpoch,
                generation: identity.generation,
                sequence: sequence,
                fields: event.fields
            ))

        case "detached", "attach-overflow":
            throw BackendTerminalCompatibilityError.invalidEvent(event.name)

        default:
            throw BackendTerminalCompatibilityError.invalidEvent(event.name)
        }

        switch eventContinuation.yield(decoded) {
        case .enqueued:
            break
        case .dropped:
            throw BackendTerminalCompatibilityError.streamOverflow(capacity: eventCapacity)
        case .terminated:
            throw BackendProtocolError.connectionClosed
        @unknown default:
            throw BackendProtocolError.connectionClosed
        }
    }

    private func decodeSnapshot(
        _ event: BackendServerEvent,
        resolvedSurface: ResolvedSurface,
        replayKey: String
    ) throws -> BackendTerminalCompatibilitySnapshot {
        let identity = try decodeIdentity(event, resolvedSurface: resolvedSurface)
        let sequence = try unsigned(event.fields["sequence"])
        let columns = try boundedUInt16(event.fields["cols"])
        let rows = try boundedUInt16(event.fields["rows"])
        let replay = try decodedBase64(
            event.fields[replayKey],
            maximumBytes: Self.maximumReplayBytes
        )
        return BackendTerminalCompatibilitySnapshot(
            surfaceID: resolvedSurface.surfaceID,
            runtimeEpoch: identity.runtimeEpoch,
            generation: identity.generation,
            sequence: sequence,
            columns: columns,
            rows: rows,
            replay: replay
        )
    }

    private func decodeIdentity(
        _ event: BackendServerEvent,
        resolvedSurface: ResolvedSurface
    ) throws -> (runtimeEpoch: UInt64, generation: UInt64) {
        let handle = try unsigned(event.fields["surface"])
        guard handle == resolvedSurface.handle,
              string(event.fields["surface_uuid"]) == resolvedSurface.surfaceID.description else {
            throw BackendTerminalCompatibilityError.invalidEvent(event.name)
        }
        let runtimeEpoch = try unsigned(event.fields["runtime_epoch"])
        let generation = try unsigned(event.fields["generation"])
        guard runtimeEpoch > 0, generation > 0 else {
            throw BackendTerminalCompatibilityError.invalidEvent(event.name)
        }
        return (runtimeEpoch, generation)
    }

    private func currentSnapshot(
        for eventName: String
    ) throws -> BackendTerminalCompatibilitySnapshot {
        guard let initialSnapshotValue else {
            throw BackendTerminalCompatibilityError.invalidEvent(eventName)
        }
        return initialSnapshotValue
    }

    private func awaitInitialSnapshot() async throws -> BackendTerminalCompatibilitySnapshot {
        if let initialSnapshotValue { return initialSnapshotValue }
        return try await withCheckedThrowingContinuation { initialWaiters.append($0) }
    }

    private func finishInitialWaiters(returning snapshot: BackendTerminalCompatibilitySnapshot) {
        let waiters = initialWaiters
        initialWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: snapshot) }
    }

    private func finishWaiters(throwing error: any Error) {
        let waiters = initialWaiters
        initialWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func fail(_ error: any Error) async {
        guard !finished else { return }
        finished = true
        eventTask?.cancel()
        eventTask = nil
        await revokeInputDelegationIfNeeded()
        await client.close()
        finishWaiters(throwing: error)
        eventContinuation.finish(throwing: error)
    }

    private func revokeInputDelegationIfNeeded() async {
        guard let delegation = inputDelegation,
              let resolvedSurface else {
            inputDelegation = nil
            nextInputSequence = nil
            return
        }
        inputDelegation = nil
        nextInputSequence = nil
        try? await inputAuthority.revokeTerminalCompatibilityInput(
            surfaceID: resolvedSurface.surfaceID,
            delegateIdentity: registrationIdentity,
            delegation: delegation
        )
    }

    private func beginInputOperation() async {
        if !inputOperationActive {
            inputOperationActive = true
            return
        }
        await withCheckedContinuation { inputOperationWaiters.append($0) }
    }

    private func endInputOperation() {
        guard inputOperationActive else { return }
        if inputOperationWaiters.isEmpty {
            inputOperationActive = false
        } else {
            inputOperationWaiters.removeFirst().resume()
        }
    }

    private func resolve(
        _ surfaceID: SurfaceID,
        in topology: CanonicalTopology
    ) throws -> ResolvedSurface {
        for workspace in topology.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    if let surface = pane.tabs.first(where: { $0.uuid == surfaceID }) {
                        guard surface.kind == "pty" else {
                            throw BackendTerminalCompatibilityError.surfaceIsNotTerminal(surfaceID)
                        }
                        return ResolvedSurface(
                            handle: surface.id,
                            surfaceID: surfaceID
                        )
                    }
                }
            }
        }
        throw BackendTerminalCompatibilityError.surfaceNotFound(surfaceID)
    }

    private func validateIdentity(_ identify: BackendIdentifyResponse) throws {
        guard identify.session == expectation.session else {
            throw BackendCanonicalSessionError.unexpectedSession(
                expected: expectation.session,
                actual: identify.session
            )
        }
        if let authority = expectation.authority, identify.authority != authority {
            throw BackendCanonicalSessionError.unexpectedAuthority(
                expected: authority,
                actual: identify.authority
            )
        }
        if let processID = expectation.processID, identify.processID != processID {
            throw BackendCanonicalSessionError.unexpectedProcessID(
                expected: processID,
                actual: identify.processID
            )
        }
    }

    private func validateInputReceipt(
        _ receipt: BackendTerminalOperationReceipt,
        requestID: UUID,
        sequence: UInt64,
        leaseGeneration: UInt64,
        encodedBytes: UInt64
    ) throws {
        guard receipt.requestID == requestID,
              receipt.status == .applied,
              receipt.kind == .input,
              receipt.sequence == sequence,
              receipt.leaseGeneration == leaseGeneration,
              receipt.replayed == false,
              receipt.encodedBytes == encodedBytes,
              receipt.orderedInputSequence.map({ $0 > 0 }) == true,
              receipt.leaseRevoked == false else {
            throw BackendProtocolError.malformedMessage
        }
    }

    private func validateInputDelegation(
        _ delegation: BackendTerminalInputDelegation,
        surfaceID: SurfaceID
    ) throws {
        guard delegation.surfaceID == surfaceID,
              delegation.delegationID != Self.nilUUID,
              delegation.delegateClientUUID == registrationIdentity.clientUUID,
              delegation.delegateProcessInstanceUUID
                == registrationIdentity.processInstanceUUID,
              delegation.delegationGeneration > 0,
              delegation.ownerLeaseGeneration > 0,
              delegation.expiresAtMilliseconds > 0,
              delegation.nextSequence > 0,
              delegation.scopes == [.text] else {
            throw BackendProtocolError.malformedMessage
        }
    }

    private static let nilUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    private func unsigned(_ value: BackendJSONValue?) throws -> UInt64 {
        switch value {
        case .unsignedInteger(let value):
            return value
        case .integer(let value) where value >= 0:
            return UInt64(value)
        default:
            throw BackendProtocolError.malformedMessage
        }
    }

    private func boundedUInt16(_ value: BackendJSONValue?) throws -> UInt16 {
        guard let result = UInt16(exactly: try unsigned(value)), result > 0 else {
            throw BackendProtocolError.malformedMessage
        }
        return result
    }

    private func string(_ value: BackendJSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private func decodedBase64(
        _ value: BackendJSONValue?,
        maximumBytes: Int
    ) throws -> Data {
        guard let encoded = string(value),
              encoded.utf8.count <= ((maximumBytes + 2) / 3) * 4 + 4,
              let data = Data(base64Encoded: encoded),
              data.count <= maximumBytes else {
            throw BackendProtocolError.malformedMessage
        }
        return data
    }
}
