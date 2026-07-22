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

        while bytesRead < maxBytes {
            let readCount = min(chunkSize, maxBytes - bytesRead)
            let chunk = (try? handle.read(upToCount: readCount)) ?? Data()
            if chunk.isEmpty {
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

        if lineStart < buffer.endIndex {
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
        endingBeforeOffset: UInt64? = nil,
        body: ([String: Any]) -> Bool
    ) -> SessionIndexJSONLReadMetrics {
        guard maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }
        defer { try? handle.close() }

        let fileEndOffset = (try? handle.seekToEnd()) ?? 0
        let pageEndOffset = min(endingBeforeOffset ?? fileEndOffset, fileEndOffset)
        guard pageEndOffset > 0 else {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }

        let includesBoundaryContext = pageEndOffset > UInt64(maxBytes)
        let candidateStartOffset: UInt64
        let readStartOffset: UInt64
        if includesBoundaryContext {
            candidateStartOffset = pageEndOffset - UInt64(maxBytes - 1)
            readStartOffset = candidateStartOffset - 1
        } else {
            candidateStartOffset = 0
            readStartOffset = 0
        }

        try? handle.seek(toOffset: readStartOffset)
        let readCount = Int(pageEndOffset - readStartOffset)
        let data = (try? handle.read(upToCount: readCount)) ?? Data()
        let payload = includesBoundaryContext ? data.dropFirst() : data[...]
        let startsOnNewline = payload.first == 0x0a
        let startsWithinRecord = includesBoundaryContext
            && data.first != 0x0a
            && !startsOnNewline
        let firstNewline = payload.firstIndex(of: 0x0a)
        let completeRecordsStart = startsWithinRecord
            ? firstNewline.map { payload.index(after: $0) } ?? payload.endIndex
            : payload.startIndex

        var recordsVisited = 0
        var lineEnd = payload.endIndex
        while lineEnd > completeRecordsStart {
            while lineEnd > completeRecordsStart,
                  payload[payload.index(before: lineEnd)] == 0x0a {
                lineEnd = payload.index(before: lineEnd)
            }
            guard lineEnd > completeRecordsStart else { break }

            let currentLineEnd = lineEnd
            let lineStart: Data.SubSequence.Index
            if let newline = payload[completeRecordsStart..<lineEnd].lastIndex(of: 0x0a) {
                lineStart = payload.index(after: newline)
                lineEnd = newline
            } else {
                lineStart = completeRecordsStart
                lineEnd = completeRecordsStart
            }
            guard lineStart < currentLineEnd else { continue }
            recordsVisited += 1
            if Self.visit(line: Data(payload[lineStart..<currentLineEnd]), body: body) {
                break
            }
        }

        let nextEndOffset: UInt64?
        if !includesBoundaryContext {
            nextEndOffset = nil
        } else if maxBytes == 1 {
            nextEndOffset = readStartOffset
        } else if data.first == 0x0a {
            nextEndOffset = candidateStartOffset
        } else if startsOnNewline {
            nextEndOffset = candidateStartOffset + 1
        } else if let firstNewline {
            let distance = payload.distance(from: payload.startIndex, to: firstNewline)
            let boundary = candidateStartOffset + UInt64(distance + 1)
            nextEndOffset = boundary < pageEndOffset ? boundary : candidateStartOffset
        } else {
            nextEndOffset = candidateStartOffset
        }
        return SessionIndexJSONLReadMetrics(
            bytesRead: data.count,
            recordsVisited: recordsVisited,
            didReachStart: !includesBoundaryContext,
            nextEndOffset: nextEndOffset
        )
    }

    /// Visits fixed-size tail pages until the callback stops or the file start is reached.
    @discardableResult
    func fromTailPages(
        url: URL,
        maxBytesPerPage: Int,
        maximumPageCount: Int? = nil,
        body: ([String: Any]) -> Bool
    ) -> SessionIndexJSONLReadMetrics {
        var endOffset: UInt64?
        var bytesRead = 0
        var recordsVisited = 0
        var didReachStart = false
        var stoppedEarly = false
        var pagesRead = 0

        repeat {
            let page = fromTail(
                url: url,
                maxBytes: maxBytesPerPage,
                endingBeforeOffset: endOffset
            ) { object in
                stoppedEarly = body(object)
                return stoppedEarly
            }
            bytesRead += page.bytesRead
            recordsVisited += page.recordsVisited
            didReachStart = page.didReachStart
            endOffset = page.nextEndOffset
            pagesRead += 1
        } while !stoppedEarly
            && !didReachStart
            && endOffset != nil
            && maximumPageCount.map({ pagesRead < $0 }) != false
            && !Task.isCancelled

        return SessionIndexJSONLReadMetrics(
            bytesRead: bytesRead,
            recordsVisited: recordsVisited,
            didReachStart: didReachStart,
            nextEndOffset: endOffset
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
