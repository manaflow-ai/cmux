import Foundation
import Network
import os

nonisolated private let logger = Logger(subsystem: "com.cmuxterm.app", category: "CloudPortForward")

/// Carries one accepted loopback connection to a service inside the Cloud VM
/// network: claims the hub, runs the SOCKS5 CONNECT over the hub's socket,
/// relays bytes both ways until either side closes, then releases the claim.
struct CloudPortForwardRelay: Sendable {
    enum RelayError: Error, LocalizedError {
        /// The hub accepted the socket but did not finish the SOCKS5 exchange
        /// in time; the claim is released so the hub can idle-stop.
        case handshakeTimedOut(Duration)

        var errorDescription: String? {
            switch self {
            case .handshakeTimedOut(let budget):
                return "The Cloud hub did not answer the SOCKS5 handshake within \(budget)."
            }
        }
    }

    let dialer: any CloudHubDialing
    /// Budget for the hub connection plus the SOCKS5 exchange, not the relay:
    /// a hub that accepts and then stalls must not hold a lease forever.
    var handshakeTimeout: Duration = .seconds(15)
    var clock: any Clock<Duration> = ContinuousClock()

    /// Returns when the connection has ended. A failure before the relay begins
    /// closes `client`, so a browser sees a connection error rather than a hang.
    func carry(_ client: NWConnection, to target: CloudPortForwardTarget, queue: DispatchQueue) async {
        let claim: CloudHubSocketClaim
        do {
            claim = try await dialer.claimHubSocket()
        } catch {
            logger.error("hub unavailable for \(target.host, privacy: .private):\(target.port, privacy: .public): \(CloudMachineLink.errorText(error), privacy: .public)")
            client.cancel()
            return
        }
        let upstream = NWConnection(to: claim.endpoint, using: .tcp)
        do {
            try await handshake(upstream, to: target, queue: queue)
        } catch {
            logger.error("SOCKS5 CONNECT to \(target.host, privacy: .private):\(target.port, privacy: .public) failed: \(CloudMachineLink.errorText(error), privacy: .public)")
            upstream.cancel()
            client.cancel()
            await claim.release()
            return
        }
        await Self.relay(client, upstream)
        await claim.release()
    }

    /// The hub connection and SOCKS5 exchange under ``handshakeTimeout``. The
    /// deadline cancels the connection, which is what unblocks a stalled
    /// receive; the loser of the race is discarded.
    private func handshake(_ upstream: NWConnection, to target: CloudPortForwardTarget, queue: DispatchQueue) async throws {
        let budget = handshakeTimeout
        let clock = self.clock
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await upstream.startAndWaitUntilReady(queue: queue)
                try await Self.connect(upstream, to: target)
            }
            group.addTask {
                try await clock.sleep(for: budget)
                upstream.cancel()
                throw RelayError.handshakeTimedOut(budget)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// The SOCKS5 handshake on a ready hub connection; on return the stream
    /// carries the tunneled connection.
    static func connect(_ upstream: NWConnection, to target: CloudPortForwardTarget) async throws {
        try await upstream.sendAll(Data(SocksV5Client.greeting))
        try SocksV5Client.checkMethodSelection(try await upstream.receiveExactly(SocksV5Client.methodSelectionLength))
        try await upstream.sendAll(Data(try SocksV5Client.connectRequest(host: target.host, port: target.port)))
        let header = try await upstream.receiveExactly(SocksV5Client.replyHeaderLength)
        // A refusal may be followed by an immediate close, so judge the reply
        // before asking for the bound address that a success carries.
        try SocksV5Client.checkReply(header)
        // Drain the bound address so the stream is positioned at the payload.
        if let trailer = try SocksV5Client.replyTrailerLength(header: header) {
            _ = try await upstream.receiveExactly(trailer)
        } else {
            let length = try await upstream.receiveExactly(1)
            _ = try await upstream.receiveExactly(SocksV5Client.domainReplyTrailerLength(lengthByte: length[0]))
        }
    }

    /// Pumps both directions. A clean end of one direction half-closes the
    /// other (the peer may still answer); a failure cancels both connections so
    /// the other pump ends too.
    static func relay(_ client: NWConnection, _ upstream: NWConnection) async {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await pump(from: client, to: upstream) }
            group.addTask { await pump(from: upstream, to: client) }
            for await endedCleanly in group where !endedCleanly {
                client.cancel()
                upstream.cancel()
            }
        }
        client.cancel()
        upstream.cancel()
    }

    private static func pump(from source: NWConnection, to sink: NWConnection) async -> Bool {
        do {
            while true {
                let (data, isComplete) = try await source.receiveChunk()
                if let data, !data.isEmpty {
                    try await sink.sendAll(data)
                }
                if isComplete {
                    try await sink.finishSending()
                    return true
                }
            }
        } catch {
            return false
        }
    }
}
