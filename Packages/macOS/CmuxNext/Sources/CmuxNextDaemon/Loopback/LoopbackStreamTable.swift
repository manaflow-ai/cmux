import Foundation
import Synchronization

/// Streams by id for one connection, shared with its reader thread.
final class LoopbackStreamTable: Sendable {
    private let streams = Mutex<[UInt64: LoopbackStream]>([:])

    func insert(_ stream: LoopbackStream) {
        streams.withLock { $0[stream.id] = stream }
    }

    func remove(_ id: UInt64) {
        _ = streams.withLock { $0.removeValue(forKey: id) }
    }

    func stream(_ id: UInt64) -> LoopbackStream? {
        streams.withLock { $0[id] }
    }

    func removeAll() -> [LoopbackStream] {
        streams.withLock { streams in
            defer { streams.removeAll() }
            return Array(streams.values)
        }
    }

    var count: Int { streams.withLock(\.count) }
}

/// Sends stream lines on one transport.
struct TransportLineSender: LoopbackLineSending {
    let transport: LineTransport

    func send(_ line: Data) -> Bool { transport.sendLine(line) }
}
