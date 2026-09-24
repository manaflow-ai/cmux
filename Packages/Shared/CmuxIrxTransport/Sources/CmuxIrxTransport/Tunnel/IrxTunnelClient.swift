import Foundation

/// Phone side of the browser tunnel lanes.
public enum IrxTunnelClient {
    /// How long the phone waits for the Mac's open reply. The Mac's own
    /// connect deadline is shorter, so this only fires on a stuck lane.
    public static let replyTimeout: Duration = .seconds(15)

    /// Opens a TCP connection from the Mac to `host:port`. On return the
    /// lane carries raw bytes; the Mac's refusal throws `IrxTunnelOpenError`.
    public static func connect(
        on connection: IrxConnection,
        host: String,
        port: Int,
        replyTimeout: Duration = replyTimeout
    ) async throws -> IrxLaneStream {
        let lane = try await connection.openLane(
            IrxLaneDescriptor(lane: .tcpConnect, host: host, port: port)
        )
        let reply: IrxTunnelOpenReply?
        do {
            reply = try await withReplyDeadline(replyTimeout, lane: lane) {
                try await lane.reader.readControlFrame(IrxTunnelOpenReply.self)
            }
        } catch {
            await lane.abort()
            throw IrxTunnelOpenError(status: .failed)
        }
        guard let reply else {
            await lane.abort()
            throw IrxTunnelOpenError(status: .failed)
        }
        guard reply.status == .connected else {
            await lane.close()
            throw IrxTunnelOpenError(status: reply.status)
        }
        return lane
    }

    /// The Mac's loopback listening ports and its tunnel policy.
    public static func listeningPorts(
        on connection: IrxConnection,
        replyTimeout: Duration = replyTimeout
    ) async throws -> IrxListeningPortsReply {
        let lane = try await connection.openLane(IrxLaneDescriptor(lane: .listeningPorts))
        do {
            let reply = try await withReplyDeadline(replyTimeout, lane: lane) {
                try await lane.reader.readControlFrame(IrxListeningPortsReply.self)
            }
            await lane.close()
            guard let reply else { throw IrxTunnelOpenError(status: .failed) }
            return reply
        } catch {
            await lane.abort()
            throw error
        }
    }

    /// Runs `read`, aborting the lane (which fails the read) at the deadline.
    private static func withReplyDeadline<T: Sendable>(
        _ timeout: Duration,
        lane: IrxLaneStream,
        _ read: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let deadline = Task {
            try await Task.sleep(for: timeout)
            await lane.abort()
        }
        defer { deadline.cancel() }
        return try await read()
    }
}
