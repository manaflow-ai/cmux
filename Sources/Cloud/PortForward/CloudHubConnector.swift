import Foundation
import Network

/// Connects to the first working private address through one claimed hub.
/// A family can blackhole independently of the other after a VM joins its VPC.
/// Race actual SOCKS CONNECT handshakes, retaining the winning stream and closing
/// every loser before returning, so terminal and browser callers share the policy.
struct CloudHubConnector: Sendable {
    var timeout: Duration = .seconds(15)
    /// A cancellable head start for the preferred family, driven by the injected clock.
    var fallbackDelay: Duration = .milliseconds(250)
    var clock: any Clock<Duration> = ContinuousClock()

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    func connect(
        endpoint: NWEndpoint,
        target: CloudPortForwardTarget,
        queue: DispatchQueue
    ) async throws -> CloudHubConnection {
        let candidates = target.hosts.map { host in
            CloudHubConnection(connection: NWConnection(to: endpoint, using: .tcp), host: host)
        }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Result<CloudHubConnection, any Error>.self) { group in
                for (index, candidate) in candidates.enumerated() {
                    group.addTask {
                        do {
                            if index > 0 { try await clock.sleep(for: fallbackDelay) }
                            try Task.checkCancellation()
                            try await handshake(candidate.connection, host: candidate.host, port: target.port, queue: queue)
                            try Task.checkCancellation()
                            return .success(candidate)
                        } catch {
                            candidate.connection.cancel()
                            return .failure(error)
                        }
                    }
                }
                defer { group.cancelAll() }
                var lastError: any Error = CancellationError()
                while let result = try await group.next() {
                    switch result {
                    case .success(let connected):
                        for other in candidates where other.connection !== connected.connection {
                            other.connection.cancel()
                        }
                        if Task.isCancelled {
                            connected.connection.cancel()
                            throw CancellationError()
                        }
                        return connected
                    case .failure(let error):
                        lastError = error
                    }
                }
                throw lastError
            }
        } onCancel: {
            for candidate in candidates { candidate.connection.cancel() }
        }
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    private func handshake(_ connection: NWConnection, host: String, port: Int, queue: DispatchQueue) async throws {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await connection.startAndWaitUntilReady(queue: queue)
                    try await CloudPortForwardRelay.connect(connection, to: CloudPortForwardTarget(host: host, port: port))
                }
                group.addTask {
                    // A real handshake deadline; completion cancels this child
                    // and expiry cancels the socket to unblock Network callbacks.
                    try await clock.sleep(for: timeout)
                    connection.cancel()
                    throw CloudPortForwardRelay.RelayError.handshakeTimedOut(timeout)
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
