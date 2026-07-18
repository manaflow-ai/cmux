internal import Foundation

/// Incremental newline-delimited JSON framing with an exact per-line bound.
struct BackendLineFramer: Sendable {
    let maximumMessageBytes: Int
    private(set) var buffer = Data()

    init(maximumMessageBytes: Int) {
        precondition(maximumMessageBytes > 0)
        self.maximumMessageBytes = maximumMessageBytes
    }

    mutating func append(_ chunk: Data) throws {
        guard buffer.count <= maximumMessageBytes,
              chunk.count <= maximumMessageBytes else {
            throw BackendProtocolError.oversizedMessage(limit: maximumMessageBytes)
        }
        buffer.append(chunk)
    }

    mutating func nextMessage() throws -> Data? {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineLength = buffer.distance(from: buffer.startIndex, to: newline)
            guard lineLength <= maximumMessageBytes else {
                throw BackendProtocolError.oversizedMessage(limit: maximumMessageBytes)
            }
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard String(data: line, encoding: .utf8) != nil else {
                throw BackendProtocolError.malformedMessage
            }
            return line
        }
        guard buffer.count <= maximumMessageBytes else {
            throw BackendProtocolError.oversizedMessage(limit: maximumMessageBytes)
        }
        return nil
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
