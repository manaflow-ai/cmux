import Foundation

/// Phone side of the browser tunnel lanes over one irx connection.
public struct IrxTunnelClient: Sendable {
    private let connection: IrxConnection
    /// How long the phone waits for the Mac's reply. The Mac's own connect
    /// deadline is shorter, so this only fires on a stuck lane.
    private let replyTimeout: Duration

    /// - Parameters:
    ///   - connection: The irx connection to the paired Mac.
    ///   - replyTimeout: How long to wait for each lane's first reply.
    public init(connection: IrxConnection, replyTimeout: Duration = .seconds(15)) {
        self.connection = connection
        self.replyTimeout = replyTimeout
    }

    /// Opens a TCP connection from the Mac to `host:port`. On return the
    /// lane carries raw bytes; the Mac's refusal throws `IrxTunnelOpenError`.
    public func connect(host: String, port: Int) async throws -> IrxLaneStream {
        let lane = try await connection.openLane(
            IrxLaneDescriptor(lane: .tcpConnect, host: host, port: port)
        )
        let reply: IrxTunnelOpenReply?
        do {
            reply = try await Self.withReplyDeadline(replyTimeout, lane: lane) {
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
    public func listeningPorts() async throws -> IrxListeningPortsReply {
        let lane = try await connection.openLane(IrxLaneDescriptor(lane: .listeningPorts))
        do {
            let reply = try await Self.withReplyDeadline(replyTimeout, lane: lane) {
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
