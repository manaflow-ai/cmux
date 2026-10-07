import Foundation
import Network
import Synchronization

/// Listens for acpmux's `catalog.changed` notification: acpmux sends it to
/// every connection when the model catalog in use changes (a fetch, a 304
/// does not). One long-lived unix-socket connection; `initialize` first, then
/// only reads. The stream ends when the daemon closes the connection.
nonisolated enum AcpmuxCatalogWatcher {
    static let changedMethod = "catalog.changed"

    /// One element per `catalog.changed`, until the connection ends. The host then reads `catalog.get`.
    static func changes(socketPath: String) -> AsyncThrowingStream<Void, any Error> {
        // One pending change is enough: the host reads the whole catalog each time.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
            let lines = LineReader()
            continuation.onTermination = { _ in connection.cancel() }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let initialize: [String: Any] = [
                        "jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-model-catalog", "version": "1"], "clientCapabilities": [:]],
                    ]
                    var payload = (try? JSONSerialization.data(withJSONObject: initialize)) ?? Data()
                    payload.append(0x0A)
                    connection.send(content: payload, completion: .contentProcessed { _ in })
                    receive(connection, lines: lines, continuation: continuation)
                case .failed(let error), .waiting(let error):
                    continuation.finish(throwing: AcpmuxStatusClient.Failure.unreachable("\(error)"))
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "cmux.next.agent-pane.catalog-watch"))
        }
    }

    /// True when `line` is a `catalog.changed` notification.
    static func isChanged(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return object["method"] as? String == changedMethod && object["id"] == nil
    }

    private static func receive(_ connection: NWConnection, lines: LineReader,
                                continuation: AsyncThrowingStream<Void, any Error>.Continuation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                for line in lines.append(data) {
                    if isChanged(line) { continuation.yield(()) }
                }
            }
            if let error {
                continuation.finish(throwing: error)
            } else if isComplete {
                continuation.finish()
            } else {
                receive(connection, lines: lines, continuation: continuation)
            }
        }
    }
}

/// Splits a byte stream into newline-terminated lines.
nonisolated final class LineReader: Sendable {
    private let buffer = Mutex(Data())
    /// Bytes kept without a newline before the reader drops them (a reply line is far smaller).
    static let maximumLine = 4 << 20

    func append(_ data: Data) -> [Data] {
        buffer.withLock { buffer in
            buffer += data
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > Self.maximumLine { buffer.removeAll() }
            return lines
        }
    }
}
