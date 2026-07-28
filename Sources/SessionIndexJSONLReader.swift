import Foundation

/// Streaming, byte-bounded JSONL reader shared by Vault index and preview paths.
struct SessionIndexJSONLReader: Sendable {
    private let chunkSize: Int
    private let maximumRecordBytes: Int

    init(
        chunkSize: Int = 64 * 1024,
        maximumRecordBytes: Int = 2 * 1024 * 1024
    ) {
        self.chunkSize = max(1, chunkSize)
        self.maximumRecordBytes = max(1, maximumRecordBytes)
    }

    /// Streams records from the beginning until the callback stops or EOF is reached.
    func fromStart(
        url: URL,
        body: ([String: Any]) -> Bool
    ) -> SessionIndexJSONLReadMetrics {
        fromStart(url: url, maximumBytes: nil, body: body)
    }

    func fromStart(
        url: URL,
        maxBytes: Int,
        body: ([String: Any]) -> Bool
    ) -> SessionIndexJSONLReadMetrics {
        guard maxBytes > 0 else {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }
        return fromStart(url: url, maximumBytes: maxBytes, body: body)
    }

    private func fromStart(
        url: URL,
        maximumBytes: Int?,
        body: ([String: Any]) -> Bool
    ) -> SessionIndexJSONLReadMetrics {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }
        defer { try? handle.close() }

        var lineData = Data()
        lineData.reserveCapacity(min(chunkSize, maximumRecordBytes))
        var isSkippingOversizedRecord = false
        var bytesRead = 0
        var recordsVisited = 0

        func append(_ segment: Data.SubSequence) {
            guard !segment.isEmpty, !isSkippingOversizedRecord else { return }
            guard lineData.count + segment.count <= maximumRecordBytes else {
                lineData = Data()
                isSkippingOversizedRecord = true
                return
            }
            lineData.append(contentsOf: segment)
        }

        func finishRecord() -> Bool {
            defer {
                lineData.removeAll(keepingCapacity: true)
                isSkippingOversizedRecord = false
            }
            guard !lineData.isEmpty || isSkippingOversizedRecord else { return false }
            recordsVisited += 1
            guard !isSkippingOversizedRecord else { return false }
            return Self.visit(line: lineData, body: body)
        }

        while maximumBytes.map({ bytesRead < $0 }) != false, !Task.isCancelled {
            let readCount = maximumBytes.map { min(chunkSize, $0 - bytesRead) } ?? chunkSize
            let chunk = (try? handle.read(upToCount: readCount)) ?? Data()
            if chunk.isEmpty {
                break
            }
            bytesRead += chunk.count

            var segmentStart = chunk.startIndex
            while let newline = chunk[segmentStart...].firstIndex(of: 0x0a) {
                append(chunk[segmentStart..<newline])
                if finishRecord() {
                    return SessionIndexJSONLReadMetrics(
                        bytesRead: bytesRead,
                        recordsVisited: recordsVisited
                    )
                }
                segmentStart = chunk.index(after: newline)
            }
            if segmentStart < chunk.endIndex {
                append(chunk[segmentStart..<chunk.endIndex])
            }
        }

        if !lineData.isEmpty || isSkippingOversizedRecord {
            _ = finishRecord()
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
            let recordLength = payload.distance(from: lineStart, to: currentLineEnd)
            if recordLength <= maximumRecordBytes,
               Self.visit(line: Data(payload[lineStart..<currentLineEnd]), body: body) {
                break
            }
        }

        // `nextEndOffset` is the next older page's exclusive `endingBeforeOffset`.
        // `nil` means no earlier bytes remain; `didReachStart` reports that same terminal state.
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
