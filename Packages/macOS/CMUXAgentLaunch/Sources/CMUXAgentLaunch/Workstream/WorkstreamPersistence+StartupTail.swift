import Foundation

// Bounded startup-tail I/O remains isolated to the persistence actor.
extension WorkstreamPersistence {
    func readTail(
        limit: Int,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> WorkstreamJournalTail {
        guard limit > 0, fileManager.fileExists(atPath: fileURL.path) else {
            return WorkstreamJournalTail(lines: [], exceededBudget: false, startOffset: 0, endOffset: 0)
        }
        let fh = try FileHandle(forReadingFrom: fileURL)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()
        guard fileSize > 0 else { return WorkstreamJournalTail(lines: [], exceededBudget: false, startOffset: 0, endOffset: 0) }
        let chunkSize = 64 * 1024
        // Include the terminating newline so a valid row at the byte cap is
        // not mistaken for a partial leading row.
        let maximumTailBytes = Self.maximumPersistedRowBytes + 1
        var offset = fileSize
        var chunks: [Data] = []
        var totalBytes = 0
        var newlineCount = 0
        let maximumRows = 10_000
        var exceededBudget = false
        while offset > 0, newlineCount < maximumRows {
            if let deadlineNanoseconds,
               uptimeNanoseconds() >= deadlineNanoseconds {
                exceededBudget = true
                break
            }
            let readSize = min(chunkSize, min(Int(offset), maximumTailBytes - totalBytes))
            guard readSize > 0 else { break }
            offset -= UInt64(readSize)
            try fh.seek(toOffset: offset)
            guard let chunk = try fh.read(upToCount: readSize), !chunk.isEmpty else { break }
            newlineCount += chunk.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            totalBytes += chunk.count
            chunks.append(chunk)
        }
        var data = Data()
        for chunk in chunks.reversed() { data.append(chunk) }
        var lineRanges = lineRanges(in: data, baseOffset: offset)
        let precedingByte: UInt8?
        if offset > 0 {
            try fh.seek(toOffset: offset - 1)
            precedingByte = try fh.read(upToCount: 1)?.first
        } else {
            precedingByte = nil
        }
        let hasLeadingPartialLine = offset > 0
            && !data.isEmpty
            && data.first != 0x0A
            && precedingByte != 0x0A
        if hasLeadingPartialLine, !lineRanges.isEmpty {
            lineRanges.removeFirst()
        }
        let lines = lineRanges.map { range in
            WorkstreamJournalLine(data: data.subdata(in: range.range), offset: range.startOffset)
        }
        return WorkstreamJournalTail(
            lines: lines,
            exceededBudget: exceededBudget,
            startOffset: offset,
            endOffset: fileSize
        )
    }

}
