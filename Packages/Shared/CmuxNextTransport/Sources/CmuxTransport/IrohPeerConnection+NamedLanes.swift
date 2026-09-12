import Foundation
import IrohLib

extension IrohPeerConnection {
    /// Cancellation belongs to the caller, not the shared stream's open task.
    func awaitNamedLane(
        _ opening: Task<any TransportLane, Never>, name: String
    ) async -> any TransportLane {
        let lane = await opening.value
        return Task.isCancelled ? DeadLane(name: name) : lane
    }

    /// Performs the one reserved open for a dialer's logical lane name.
    /// All concurrent callers await this same result, so a loser cannot reset
    /// a stream that the remote peer has already adopted as the named lane.
    func openNamedLane(_ name: String) async -> any TransportLane {
        defer { laneOpenTasks.removeValue(forKey: name) }
        var openedStream: BiStream?
        do {
            let stream = try await connection.openBi()
            openedStream = stream
            guard !closedFlag, !Task.isCancelled else { throw TransportError.pipeClosed }
            let channel = IrohLaneChannel(
                send: stream.send(), recv: stream.recv(),
                onProtocolError: { [weak self] in
                    await self?.protocolViolation()
                })
            try await channel.sendFrame(
                Frame(type: Self.laneOpenType, payload: ["name": .string(name)]))
            return try await completeNamedLaneOpen(name, stream: stream, channel: channel)
        } catch {
            if let openedStream { await closeUnadoptedStream(openedStream) }
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) lane open FAILED \
                    (dialer) name=\(name, privacy: .public) \
                    error=\(String(describing: error), privacy: .public) -> dead lane
                    """)
            }
            return DeadLane(name: name)
        }
    }

    /// Takes ownership after the native opening handshake has suspended.
    /// Keeps an inbound winner and closes only the unadopted duplicate.
    /// The caller closes the unadopted stream if registration throws.
    func completeNamedLaneOpen(
        _ name: String, stream: BiStream, channel: IrohLaneChannel
    ) async throws -> IrohLane {
        guard !closedFlag, !Task.isCancelled else {
            throw TransportError.pipeClosed
        }
        if let existing = lanes[name] {
            // Inbound processing can adopt this name while sendFrame yields.
            // Never replace its consumer or lose ownership of its QUIC stream.
            await closeUnadoptedStream(stream)
            return existing
        }
        guard lanes.count < Self.maxLaneCount else { throw TransportError.pipeClosed }
        let lane = makeLane(name: name, channel: channel)
        lanes[name] = lane
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) lane opened \
                (dialer) name=\(name, privacy: .public)
                """)
        }
        return lane
    }
}
