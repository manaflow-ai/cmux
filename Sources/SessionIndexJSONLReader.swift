import Darwin
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

    /// Opens one regular-file generation and fixes the readable boundary to
    /// its size at open time. Callers can combine start and tail reads without
    /// reopening a transcript path that may rotate between passes.
    func withFileSnapshot<Result>(
        url: URL,
        body: (FileHandle, UInt64) throws -> Result
    ) rethrows -> Result? {
        guard let snapshot = regularFileSnapshot(forReadingFrom: url) else {
            return nil
        }
        defer { try? snapshot.handle.close() }
        return try body(snapshot.handle, snapshot.endOffset)
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
        withFileSnapshot(url: url) { handle, fileEndOffset in
            fromStart(
                fileHandle: handle,
                fileEndOffset: fileEndOffset,
                maximumBytes: maximumBytes,
                body: body
            )
        } ?? SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
    }

    func fromStart(
        fileHandle: FileHandle,
        fileEndOffset: UInt64,
        maxBytes: Int,
        body: ([String: Any]) -> Bool
    ) -> SessionIndexJSONLReadMetrics {
        guard maxBytes > 0 else {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }
        return fromStart(
            fileHandle: fileHandle,
            fileEndOffset: fileEndOffset,
            maximumBytes: maxBytes,
            body: body
        )
    }

    private func fromStart(
        fileHandle handle: FileHandle,
        fileEndOffset: UInt64,
        maximumBytes: Int?,
        body: ([String: Any]) -> Bool
    ) -> SessionIndexJSONLReadMetrics {
        do {
            try handle.seek(toOffset: 0)
        } catch {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }
        let readEndOffset = min(
            fileEndOffset,
            UInt64(maximumBytes ?? Int.max)
        )

        var lineData = Data()
        lineData.reserveCapacity(min(chunkSize, maximumRecordBytes))
        var isSkippingOversizedRecord = false
        var bytesRead = 0
        var recordsVisited = 0
        var didSkipOversizedRecord = false
        var didEncounterMalformedRecord = false

        func append(_ segment: Data.SubSequence) {
            guard !segment.isEmpty, !isSkippingOversizedRecord else { return }
            guard lineData.count + segment.count <= maximumRecordBytes else {
                lineData = Data()
                isSkippingOversizedRecord = true
                didSkipOversizedRecord = true
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
            guard let shouldStop = Self.visit(line: lineData, body: body) else {
                didEncounterMalformedRecord = true
                return false
            }
            return shouldStop
        }

        while UInt64(bytesRead) < readEndOffset, !Task.isCancelled {
            let readCount = Int(min(
                UInt64(chunkSize),
                readEndOffset - UInt64(bytesRead)
            ))
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
                        recordsVisited: recordsVisited,
                        didSkipOversizedRecord: didSkipOversizedRecord,
                        didEncounterMalformedRecord: didEncounterMalformedRecord
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
            recordsVisited: recordsVisited,
            didSkipOversizedRecord: didSkipOversizedRecord,
            didEncounterMalformedRecord: didEncounterMalformedRecord
        )
    }

    func fromTail(
        url: URL,
        maxBytes: Int,
        endingBeforeOffset: UInt64? = nil,
        body: ([String: Any]) -> Bool
    ) -> SessionIndexJSONLReadMetrics {
        guard maxBytes > 0 else {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }
        return withFileSnapshot(url: url) { handle, fileEndOffset in
            fromTail(
                fileHandle: handle,
                fileEndOffset: fileEndOffset,
                maxBytes: maxBytes,
                endingBeforeOffset: endingBeforeOffset,
                body: body
            )
        } ?? SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
    }

    func fromTail(
        fileHandle handle: FileHandle,
        fileEndOffset: UInt64,
        maxBytes: Int,
        endingBeforeOffset: UInt64? = nil,
        body: ([String: Any]) -> Bool
    ) -> SessionIndexJSONLReadMetrics {
        guard maxBytes > 0 else {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }
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

        do {
            try handle.seek(toOffset: readStartOffset)
        } catch {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }
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

        // `data.first` is the byte immediately before `payload`. If the visible
        // suffix already reaches the record limit, the complete record exceeds it.
        let leadingFragmentEnd = firstNewline ?? payload.endIndex
        let skippedLeadingFragmentByteCount = startsWithinRecord
            ? payload.distance(from: payload.startIndex, to: leadingFragmentEnd)
            : 0
        var recordsVisited = 0
        var didSkipOversizedRecord =
            startsWithinRecord && skippedLeadingFragmentByteCount >= maximumRecordBytes
        var didEncounterMalformedRecord = false
        var lineEnd = payload.endIndex
        recordLoop: while lineEnd > completeRecordsStart {
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
            guard recordLength <= maximumRecordBytes else {
                didSkipOversizedRecord = true
                continue
            }
            guard let shouldStop = Self.visit(
                line: Data(payload[lineStart..<currentLineEnd]),
                body: body
            ) else {
                didEncounterMalformedRecord = true
                continue
            }
            if shouldStop {
                break recordLoop
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
            didSkipOversizedRecord: didSkipOversizedRecord,
            didEncounterMalformedRecord: didEncounterMalformedRecord,
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
        guard maxBytesPerPage > 0 else {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }
        return withFileSnapshot(url: url) { handle, fileEndOffset in
            fromTailPages(
                fileHandle: handle,
                fileEndOffset: fileEndOffset,
                maxBytesPerPage: maxBytesPerPage,
                maximumPageCount: maximumPageCount,
                body: body
            )
        } ?? SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
    }

    @discardableResult
    func fromTailPages(
        fileHandle: FileHandle,
        fileEndOffset: UInt64,
        maxBytesPerPage: Int,
        maximumPageCount: Int? = nil,
        body: ([String: Any]) -> Bool
    ) -> SessionIndexJSONLReadMetrics {
        guard maxBytesPerPage > 0 else {
            return SessionIndexJSONLReadMetrics(bytesRead: 0, recordsVisited: 0)
        }
        var endOffset: UInt64?
        var bytesRead = 0
        var recordsVisited = 0
        var didReachStart = false
        var didSkipOversizedRecord = false
        var didEncounterMalformedRecord = false
        var stoppedEarly = false
        var pagesRead = 0

        repeat {
            let page = fromTail(
                fileHandle: fileHandle,
                fileEndOffset: fileEndOffset,
                maxBytes: maxBytesPerPage,
                endingBeforeOffset: endOffset
            ) { object in
                stoppedEarly = body(object)
                return stoppedEarly
            }
            bytesRead += page.bytesRead
            recordsVisited += page.recordsVisited
            didReachStart = page.didReachStart
            didSkipOversizedRecord =
                didSkipOversizedRecord || page.didSkipOversizedRecord
            didEncounterMalformedRecord =
                didEncounterMalformedRecord || page.didEncounterMalformedRecord
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
            didSkipOversizedRecord: didSkipOversizedRecord,
            didEncounterMalformedRecord: didEncounterMalformedRecord,
            nextEndOffset: endOffset
        )
    }

    private func regularFileSnapshot(
        forReadingFrom url: URL
    ) -> (handle: FileHandle, endOffset: UInt64)? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return (
            FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            UInt64(status.st_size)
        )
    }

    private static func visit(
        line: Data,
        body: ([String: Any]) -> Bool
    ) -> Bool? {
        autoreleasepool {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                return nil
            }
            return body(object)
        }
    }
}
