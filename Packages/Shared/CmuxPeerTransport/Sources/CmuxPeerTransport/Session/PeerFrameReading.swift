public import CmuxPeerTransportCore
import Foundation

/// Bounded incremental frame reads shared by both session halves: read stream
/// chunks into a buffer until one decodable prefix appears, preserving any
/// bytes that follow it (those belong to the application protocol).
struct PeerFrameReader: Sendable {
    struct DeadlineExceeded: Error, Sendable {}
    struct StreamEnded: Error, Sendable {}
    struct FrameTooLarge: Error, Sendable {}

    let stream: PeerByteStream
    let byteBound: Int
    let deadline: Duration
    let clock: ContinuousClock

    /// Reads until `decode` returns a result, the byte bound is exceeded, the
    /// stream ends, or the deadline passes. `decode` throws its codec's
    /// incomplete-frame error to request more bytes; any other decode error
    /// propagates. Returns the decoded value plus the unconsumed remainder.
    func readFrame<Decoded>(
        isIncomplete: @escaping @Sendable (any Error) -> Bool,
        decode: @escaping @Sendable (Data) throws -> (value: Decoded, consumed: Int)
    ) async throws -> (value: Decoded, remainder: Data) where Decoded: Sendable {
        let stream = self.stream
        let byteBound = self.byteBound
        return try await withThrowingTaskGroup(
            of: (value: Decoded, remainder: Data).self
        ) { group in
            group.addTask {
                var buffer = Data()
                while true {
                    do {
                        let decoded = try decode(buffer)
                        let remainder = buffer.suffix(from: decoded.consumed)
                        return (decoded.value, Data(remainder))
                    } catch where isIncomplete(error) {
                        // Need more bytes.
                    }
                    guard buffer.count <= byteBound else {
                        throw FrameTooLarge()
                    }
                    guard let chunk = try await stream.read() else {
                        throw StreamEnded()
                    }
                    buffer.append(chunk)
                }
            }
            group.addTask { [deadline, clock] in
                try await clock.sleep(for: deadline)
                throw DeadlineExceeded()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw DeadlineExceeded()
            }
            return first
        }
    }
}
