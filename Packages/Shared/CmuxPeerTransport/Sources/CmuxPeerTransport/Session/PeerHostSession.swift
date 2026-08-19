public import CMUXMobileCore
public import CmuxPeerTransportCore
public import Foundation

/// How an admitted host session ended.
public struct PeerSessionExit: Sendable, Equatable {
    public let reason: PeerSessionCloseReason

    public init(reason: PeerSessionCloseReason) {
        self.reason = reason
    }
}

/// A client-opened application lane surfaced on the host. `initialBytes`
/// holds application bytes that arrived in the same reads as the header.
public enum PeerInboundApplicationLane: Sendable {
    case terminal(resourceID: String, cursor: UInt64?, initialBytes: Data, stream: PeerByteStream)
    case artifact(resourceID: String, offset: UInt64, initialBytes: Data, stream: PeerByteStream)
}

/// The host half of an admitted `cmux/mobile/2` session. Produced only by
/// `PeerHostSessionAcceptor.accept`, so holding a value means the grant
/// verified and the accepted ack was written.
public actor PeerHostSession {
    public nonisolated let peerEndpointID: String
    public nonisolated let grant: PeerVerifiedGrant
    public let controlTransport: any CmxByteTransport

    private let connection: PeerQuicConnection
    private let codec: PeerLaneHeaderCodec
    private let admission: PeerAdmissionController
    private var localCloseReason: String?
    private var revalidationTask: Task<Void, Never>?

    init(
        connection: PeerQuicConnection,
        controlTransport: any CmxByteTransport,
        codec: PeerLaneHeaderCodec,
        admission: PeerAdmissionController,
        grant: PeerVerifiedGrant
    ) {
        self.connection = connection
        self.controlTransport = controlTransport
        self.codec = codec
        self.admission = admission
        self.grant = grant
        self.peerEndpointID = connection.remoteEndpointID
    }

    /// Accept loop for client-opened bidirectional application lanes.
    /// Malformed lanes and duplicate control lanes are reset; the stream
    /// finishes when the connection closes.
    public nonisolated func applicationLanes() -> AsyncStream<PeerInboundApplicationLane> {
        let connection = connection
        let codec = codec
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let stream: PeerByteStream
                    do {
                        stream = try await connection.acceptBi()
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
                        switch header {
                        case let .terminal(resourceID, cursor):
                            continuation.yield(
                                .terminal(
                                    resourceID: resourceID.value,
                                    cursor: cursor,
                                    initialBytes: remainder,
                                    stream: stream
                                )
                            )
                        case let .artifact(resourceID, offset):
                            continuation.yield(
                                .artifact(
                                    resourceID: resourceID.value,
                                    offset: offset,
                                    initialBytes: remainder,
                                    stream: stream
                                )
                            )
                        case .control, .serverEvents:
                            await stream.reset()
                        }
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

    /// Opens one host→client server-event lane resumed after `cursor`.
    public func openServerEventLane(cursor: UInt64?) async throws -> PeerByteStream {
        let stream = try await connection.openUni()
        let frame = try codec.encode(.serverEvents(cursor: cursor))
        try await stream.write(frame)
        return stream
    }

    /// Starts the ≤30s broker revalidation monitor. A confirmed revoke or
    /// grant expiry closes the connection; connectivity failures preserve it.
    public func startRevalidationMonitor() {
        guard revalidationTask == nil else { return }
        let admission = admission
        let grant = grant
        revalidationTask = Task { [weak self] in
            let reason = await admission.revalidationMonitor(grant: grant)
            switch reason {
            case .revoked:
                await self?.close(reason: "grant-revoked")
            case .local(let description) where description == "grant-expired":
                await self?.close(reason: "grant-expired")
            case .local, .remote:
                break
            }
        }
    }

    public func close(reason: String) async {
        if localCloseReason == nil {
            localCloseReason = reason
        }
        revalidationTask?.cancel()
        connection.close(reason: reason)
    }

    public func awaitExit() async -> PeerSessionExit {
        let description = await connection.awaitClosed()
        revalidationTask?.cancel()
        if let localCloseReason {
            let reason: PeerSessionCloseReason =
                localCloseReason == "grant-revoked"
                ? .revoked : .local(localCloseReason)
            return PeerSessionExit(reason: reason)
        }
        return PeerSessionExit(reason: .remote(description))
    }

    public nonisolated func routeDiagnostics() -> PeerConnectionRouteDiagnostics {
        connection.routeDiagnostics()
    }
}

/// Admits one inbound connection: first control stream, one grant check, one
/// ack. Anything else closes the connection without a replacement.
public struct PeerHostSessionAcceptor: Sendable {
    public let configuration: PeerProtocolConfiguration
    public let firstHeaderDeadline: Duration

    public init(
        configuration: PeerProtocolConfiguration = .cmuxMobileV2,
        firstHeaderDeadline: Duration = .seconds(5)
    ) {
        self.configuration = configuration
        self.firstHeaderDeadline = firstHeaderDeadline
    }

    /// Returns an admitted session or nil after closing the connection.
    public func accept(
        connection: PeerQuicConnection,
        admission: PeerAdmissionController
    ) async -> PeerHostSession? {
        let codec: PeerLaneHeaderCodec
        do {
            codec = try PeerLaneHeaderCodec(configuration: configuration)
        } catch {
            connection.close(reason: "invalid protocol configuration")
            return nil
        }

        let control: PeerByteStream
        do {
            control = try await withDeadline(firstHeaderDeadline) {
                try await connection.acceptBi()
            }
        } catch {
            connection.close(reason: "no control stream")
            return nil
        }

        let reader = PeerFrameReader(
            stream: control,
            byteBound: 1 << 14,
            deadline: firstHeaderDeadline,
            clock: ContinuousClock()
        )
        let header: PeerLaneHeader
        let remainder: Data
        do {
            (header, remainder) = try await reader.readFrame(
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
        } catch {
            connection.close(reason: "invalid first frame")
            return nil
        }

        guard case let .control(credential) = header else {
            connection.close(reason: "first stream not control")
            return nil
        }

        let decision = await admission.admit(
            credential: credential.token,
            expectedInitiatorEndpointID: connection.remoteEndpointID
        )
        let ackCodec = PeerAdmissionAckCodec()
        switch decision {
        case let .admitted(grant):
            let expiry = UInt64(max(0, grant.expiresAt.timeIntervalSince1970))
            guard
                let frame = try? ackCodec.encode(
                    .accepted(grantExpiryUnixSeconds: expiry)
                ),
                (try? await control.write(frame)) != nil
            else {
                connection.close(reason: "ack write failed")
                return nil
            }
            let transport = PeerStreamByteTransport(
                stream: control,
                initialBytes: remainder,
                awaitConnectionClosed: { _ = await connection.awaitClosed() }
            )
            return PeerHostSession(
                connection: connection,
                controlTransport: transport,
                codec: codec,
                admission: admission,
                grant: grant
            )
        case let .denied(reason):
            let denialReason = Self.denialReason(for: reason)
            if let frame = try? ackCodec.encode(
                .denied(reason: denialReason, message: reason)
            ) {
                try? await control.write(frame)
                try? await control.finish()
            }
            // An immediate close would discard the unacked denial ack before
            // the client reads it. The client closes after reading the
            // denial; this bounded backstop covers a client that never does.
            let deadline = firstHeaderDeadline
            Task {
                _ = await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        _ = await connection.awaitClosed()
                    }
                    group.addTask {
                        try await ContinuousClock().sleep(for: deadline)
                    }
                    _ = try? await group.next()
                    group.cancelAll()
                    return ()
                }
                connection.close(reason: "admission denied")
            }
            return nil
        }
    }

    private static func denialReason(for reason: String) -> PeerAdmissionDenialReason {
        switch reason {
        case "invalid-grant":
            return .credentialInvalid
        case "expired-grant":
            return .credentialExpired
        case "denied-sticky", "revoked":
            return .credentialRevoked
        case "endpoint-mismatch":
            return .bindingMismatch
        default:
            return .unspecified
        }
    }

    private func withDeadline<Value: Sendable>(
        _ deadline: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await ContinuousClock().sleep(for: deadline)
                throw PeerFrameReader.DeadlineExceeded()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw PeerFrameReader.DeadlineExceeded()
            }
            return first
        }
    }
}
