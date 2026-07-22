import Foundation

/// Streaming, byte-bounded JSONL reader shared by Vault index and preview paths.
struct SessionIndexJSONLReader: Sendable {
    private let chunkSize: Int

    init(chunkSize: Int = 64 * 1024) {
        self.chunkSize = max(1, chunkSize)
    }

    func fromStart(
        url: URL,
        maxBytes: Int,
        body: ([String: Any]) -> Bool
    ) -> SessionIndexJSONLReadMetrics {
        guard maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }
        defer { try? handle.close() }

        var buffer = Data()
        var lineStart = buffer.startIndex
        var bytesRead = 0
        var recordsVisited = 0
        var reachedEnd = false

        while bytesRead < maxBytes {
            let readCount = min(chunkSize, maxBytes - bytesRead)
            let chunk = (try? handle.read(upToCount: readCount)) ?? Data()
            if chunk.isEmpty {
                reachedEnd = true
                break
            }
            bytesRead += chunk.count
            buffer.append(chunk)

            while let newline = buffer[lineStart...].firstIndex(of: 0x0a) {
                let line = Data(buffer[lineStart..<newline])
                lineStart = buffer.index(after: newline)
                guard !line.isEmpty else { continue }
                recordsVisited += 1
                if Self.visit(line: line, body: body) {
                    return SessionIndexJSONLReadMetrics(
                        bytesRead: bytesRead,
                        recordsVisited: recordsVisited
                    )
                }
            }

            if lineStart > buffer.startIndex,
               buffer.distance(from: buffer.startIndex, to: lineStart) >= chunkSize {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
                lineStart = buffer.startIndex
            }
        }

        if reachedEnd, lineStart < buffer.endIndex {
            let line = Data(buffer[lineStart..<buffer.endIndex])
            if !line.isEmpty {
                recordsVisited += 1
                _ = Self.visit(line: line, body: body)
            }
        }
        return SessionIndexJSONLReadMetrics(
            bytesRead: bytesRead,
            recordsVisited: recordsVisited
        )
    }

    func fromTail(
        url: URL,
        maxBytes: Int,
        body: ([String: Any]) -> Bool
    ) -> SessionIndexJSONLReadMetrics {
        guard maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }
        defer { try? handle.close() }

        let endOffset = (try? handle.seekToEnd()) ?? 0
        let requestedBytes = min(UInt64(maxBytes), endOffset)
        let startOffset = endOffset - requestedBytes
        try? handle.seek(toOffset: startOffset)
        let data = (try? handle.read(upToCount: Int(requestedBytes))) ?? Data()
        var lines = data.split(separator: 0x0a, omittingEmptySubsequences: true)
        if startOffset > 0, !lines.isEmpty {
            lines.removeFirst()
        }

        var recordsVisited = 0
        for line in lines.reversed() {
            recordsVisited += 1
            if Self.visit(line: Data(line), body: body) {
                break
            }
        }
        return SessionIndexJSONLReadMetrics(
            bytesRead: data.count,
            recordsVisited: recordsVisited
        )
    }

    private static func visit(
        line: Data,
        body: ([String: Any]) -> Bool
    ) -> Bool {
        autoreleasepool {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                return false
            }
            return body(object)
        }
    }
}
