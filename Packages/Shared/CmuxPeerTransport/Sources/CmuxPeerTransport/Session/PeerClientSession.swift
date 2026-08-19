public import CMUXMobileCore
public import CmuxPeerTransportCore
public import Foundation

/// A host-opened server-event lane surfaced on the client. `initialBytes`
/// holds event bytes that arrived in the same reads as the lane header.
public struct PeerInboundEventLane: Sendable {
    public let cursor: UInt64?
    public let initialBytes: Data
    public let stream: PeerByteStream

    public init(cursor: UInt64?, initialBytes: Data, stream: PeerByteStream) {
        self.cursor = cursor
        self.initialBytes = initialBytes
        self.stream = stream
    }
}

/// The client half of an admitted `cmux/mobile/2` session.
///
/// Produced only by `PeerClientSessionFactory.establish`, so holding a value
/// means admission succeeded and the control stream is live.
public actor PeerClientSession: PeerSessionHandle {
    public let controlTransport: any CmxByteTransport
    public nonisolated let remoteEndpointID: String

    private let connection: PeerQuicConnection
    private let codec: PeerLaneHeaderCodec
    private var localCloseReason: String?

    init(
        connection: PeerQuicConnection,
        controlTransport: any CmxByteTransport,
        codec: PeerLaneHeaderCodec
    ) {
        self.connection = connection
        self.controlTransport = controlTransport
        self.codec = codec
        self.remoteEndpointID = connection.remoteEndpointID
    }

    /// Opens one terminal lane; the header is written before return.
    public func openTerminalLane(
        resourceID: String,
        cursor: UInt64?
    ) async throws -> PeerByteStream {
        let lane = try PeerLaneHeader.terminal(
            resourceID: PeerResourceID(resourceID),
            cursor: cursor
        )
        return try await openLane(header: lane)
    }

    /// Opens one artifact lane resumed at `offset`.
    public func openArtifactLane(
        resourceID: String,
        offset: UInt64
    ) async throws -> PeerByteStream {
        let lane = try PeerLaneHeader.artifact(
            resourceID: PeerResourceID(resourceID),
            offset: offset
        )
        return try await openLane(header: lane)
    }

    /// Accept loop for host-opened unidirectional server-event lanes.
    /// Malformed or unexpected lanes are dropped and the loop continues; the
    /// stream finishes when the connection closes.
    public nonisolated func serverEventLanes() -> AsyncStream<PeerInboundEventLane> {
        let connection = connection
        let codec = codec
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let stream: PeerByteStream
                    do {
                        stream = try await connection.acceptUni()
                    } catch {
                        break
                    }
                    let reader = PeerFrameReader(
                        stream: stream,
                        byteBound: 1 << 14,
                        deadline: .seconds(5),
                        clock: ContinuousClock()
                    )
                    do {
                        let (header, remainder) = try await reader.readFrame(
                            isIncomplete: { error in
                                if case .incompleteFrame = error as? PeerLaneHeaderCodecError {
                                    return true
                                }
                                return false
                            },
                            decode: { buffer in
                                let decoded = try codec.decodePrefix(buffer)
                                return (decoded.header, decoded.consumedByteCount)
                            }
                        )
                        guard case let .serverEvents(cursor) = header else {
                            await stream.reset()
                            continue
                        }
                        continuation.yield(
                            PeerInboundEventLane(
                                cursor: cursor,
                                initialBytes: remainder,
                                stream: stream
                            )
                        )
                    } catch {
                        await stream.reset()
                        continue
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func close(reason: String) async {
        if localCloseReason == nil {
            localCloseReason = reason
        }
        connection.close(reason: reason)
    }

    public func awaitClose() async -> PeerSessionCloseReason {
        let description = await connection.awaitClosed()
        if let localCloseReason {
            return .local(localCloseReason)
        }
        return .remote(description)
    }

    public nonisolated func routeDiagnostics() -> PeerConnectionRouteDiagnostics {
        connection.routeDiagnostics()
    }

    private func openLane(header: PeerLaneHeader) async throws -> PeerByteStream {
        let stream = try await connection.openBi()
        let frame = try codec.encode(header)
        try await stream.write(frame)
        return stream
    }
}

/// Performs single-phase admission over a dialed connection.
public struct PeerClientSessionFactory: Sendable {
    public let configuration: PeerProtocolConfiguration
    public let ackDeadline: Duration

    public init(
        configuration: PeerProtocolConfiguration = .cmuxMobileV2,
        ackDeadline: Duration = .seconds(5)
    ) {
        self.configuration = configuration
        self.ackDeadline = ackDeadline
    }

    /// Opens the control stream, presents the pair grant, and awaits the
    /// host's single admission ack. A denial maps to
    /// `PeerDialFailure.authorizationDenied` for credential-class reasons so
    /// the supervisor's sticky-denial policy applies.
    public func establish(
        connection: PeerQuicConnection,
        credential: String
    ) async throws -> PeerClientSession {
        let codec = try PeerLaneHeaderCodec(configuration: configuration)
        let control = try await connection.openBi()
        let header = try PeerLaneHeader.control(
            credential: PeerPairGrantCredential(token: credential)
        )
        try await control.write(codec.encode(header))

        let reader = PeerFrameReader(
            stream: control,
            byteBound: 1 << 12,
            deadline: ackDeadline,
            clock: ContinuousClock()
        )
        let ackCodec = PeerAdmissionAckCodec()
        let ack: PeerAdmissionAck
        let remainder: Data
        do {
            (ack, remainder) = try await reader.readFrame(
                isIncomplete: { error in
                    if case .incompleteFrame = error as? PeerAdmissionAckCodecError {
                        return true
                    }
                    return false
                },
                decode: { buffer in
                    let decoded = try ackCodec.decodePrefix(buffer)
                    return (decoded.ack, decoded.consumedByteCount)
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch is PeerFrameReader.DeadlineExceeded {
            connection.close(reason: "admission ack deadline")
            throw PeerDialFailure(
                classification: .unreachable,
                reason: "admission ack deadline"
            )
        } catch {
            connection.close(reason: "admission protocol failure")
            throw PeerDialFailure(
                classification: .transient,
                reason: "admission protocol failure"
            )
        }

        switch ack {
        case .accepted:
            let transport = PeerStreamByteTransport(
                stream: control,
                initialBytes: remainder,
                awaitConnectionClosed: { _ = await connection.awaitClosed() }
            )
            return PeerClientSession(
                connection: connection,
                controlTransport: transport,
                codec: codec
            )
        case let .denied(reason, message):
            connection.close(reason: "admission denied")
            switch reason {
            case .credentialInvalid, .credentialExpired, .credentialRevoked, .bindingMismatch:
                throw PeerDialFailure(
                    classification: .authorizationDenied,
                    reason: "\(reason): \(message)"
                )
            case .busy, .unspecified:
                throw PeerDialFailure(
                    classification: .transient,
                    reason: "\(reason): \(message)"
                )
            }
        }
    }
}
