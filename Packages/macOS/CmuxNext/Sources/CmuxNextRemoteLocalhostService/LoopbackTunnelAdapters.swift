public import CmuxNextDaemon
public import CmuxNextRemoteLocalhost
public import Foundation

/// Opens proxy tunnels on one machine's `LoopbackForwardClient`.
public struct DaemonLoopbackOpener: LoopbackTunnelOpening {
    public let client: LoopbackForwardClient

    public init(client: LoopbackForwardClient) { self.client = client }

    public func openTunnel(host: String, port: UInt16) async throws(LoopbackTunnelFailure) -> any LoopbackTunnel {
        do {
            return DaemonLoopbackTunnel(stream: try await client.open(host: host, port: port))
        } catch let error as LoopbackForwardError {
            throw Self.failure(error)
        } catch {
            throw .other(String(describing: error))
        }
    }

    public static func failure(_ error: LoopbackForwardError) -> LoopbackTunnelFailure {
        switch error {
        case .unsupported: .unsupported
        case .disabled: .disabled
        case .deniedPort: .portNotAllowed
        case .refused: .refused
        case .unavailable(let detail): .unavailable(detail)
        case .timedOut, .limit, .deniedHost, .other: .other(error.description)
        }
    }
}

/// A daemon `LoopbackStream` as the proxy's `LoopbackTunnel`.
public struct DaemonLoopbackTunnel: LoopbackTunnel {
    public let stream: LoopbackStream
    public let events: AsyncStream<LoopbackTunnelEvent>

    public init(stream: LoopbackStream) {
        self.stream = stream
        let source = stream.events
        // concurrency-allow: a pass-through of a stream already bounded by the credit window
        events = AsyncStream { continuation in
            // task-owner: ends when the daemon stream ends (its last event is .closed)
            let task = Task {
                for await event in source {
                    switch event {
                    case .data(let data): continuation.yield(.data(data))
                    case .eof: continuation.yield(.eof)
                    case .closed(let error): continuation.yield(.closed(error: error?.description))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func write(_ data: Data) async throws { try await stream.write(data) }
    public func consumed(_ count: Int) { stream.consumed(count) }
    public func shutdownWrite() { stream.shutdownWrite() }
    public func close() { stream.close() }
}
