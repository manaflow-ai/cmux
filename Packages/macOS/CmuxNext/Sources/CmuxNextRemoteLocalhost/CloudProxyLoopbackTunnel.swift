import Foundation
import Network

/// A byte tunnel established through the authenticated `cmux-cloud` proxy.
struct CloudProxyLoopbackTunnel: LoopbackTunnel {
    let events: AsyncStream<LoopbackTunnelEvent>
    private let connection: NWConnection

    init(connection: NWConnection, initialData: Data) {
        self.connection = connection
        let source = connection
        events = AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            // task-owner: the tunnel's receive side; EOF, an error, cancellation, or stream termination ends it.
            let task = Task {
                if !initialData.isEmpty,
                   !Self.yield(.data(initialData), to: continuation, connection: source) { return }
                // wakeup-allow: every iteration awaits Network.framework for the next bytes or EOF.
                while !Task.isCancelled {
                    do {
                        let (data, complete) = try await source.receiveChunk(max: 16 * 1024)
                        if let data, !data.isEmpty,
                           !Self.yield(.data(data), to: continuation, connection: source) { return }
                        if complete {
                            continuation.yield(.eof)
                            continuation.finish()
                            return
                        }
                    } catch {
                        continuation.yield(.closed(error: String(describing: error)))
                        continuation.finish()
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                source.cancel()
            }
        }
    }

    func write(_ data: Data) async throws { try await connection.sendAll(data) }

    func consumed(_: Int) {}

    func shutdownWrite() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    func close() { connection.cancel() }

    private static func yield(
        _ event: LoopbackTunnelEvent,
        to continuation: AsyncStream<LoopbackTunnelEvent>.Continuation,
        connection: NWConnection
    ) -> Bool {
        switch continuation.yield(event) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            // A byte gap would corrupt the HTTP/TLS stream. Fail closed and
            // let the proxy cancel its client instead of buffering without bound.
            connection.cancel()
            continuation.finish()
            return false
        @unknown default:
            connection.cancel()
            continuation.finish()
            return false
        }
    }
}
