import Foundation

struct AgentSessionOutputLineBuffer {
    private static let maxBufferedBytes = 1024 * 1024

    private var buffer = Data()

    var bufferedByteCountForTesting: Int {
        buffer.count
    }

    mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let availableByteCount = max(1, Self.maxBufferedBytes - buffer.count)
            let chunkEnd = data.index(
                cursor,
                offsetBy: min(availableByteCount, data.distance(from: cursor, to: data.endIndex))
            )
            buffer.append(contentsOf: data[cursor..<chunkEnd])
            cursor = chunkEnd
            drainBufferedLines(into: &lines)
            if buffer.count >= Self.maxBufferedBytes {
                lines.append(String(decoding: buffer, as: UTF8.self) + "\n")
                buffer.removeAll(keepingCapacity: true)
            }
        }
        return lines
    }

    mutating func flush() -> [String] {
        guard !buffer.isEmpty else { return [] }
        let text = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return [text]
    }

    private mutating func drainBufferedLines(into lines: inout [String]) {
        var cursor = buffer.startIndex
        var consumedEnd: Data.Index?
        while cursor < buffer.endIndex,
              let newlineIndex = buffer[cursor...].firstIndex(of: 0x0A) {
            let lineData = buffer[cursor..<newlineIndex]
            lines.append(String(decoding: lineData, as: UTF8.self) + "\n")
            cursor = buffer.index(after: newlineIndex)
            consumedEnd = cursor
        }
        if let consumedEnd {
            buffer.removeSubrange(buffer.startIndex..<consumedEnd)
        }
    }
}
