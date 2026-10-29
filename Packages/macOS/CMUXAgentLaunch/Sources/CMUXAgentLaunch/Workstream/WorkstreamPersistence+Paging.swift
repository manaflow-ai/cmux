import Foundation

// Bounded reverse-page reads share the persistence actor and its decoder.
extension WorkstreamPersistence {
    /// Loads up to `limit` items ending before `endOffset`. Order in the
    /// returned array is oldest-first. `startOffset` can be passed back
    /// as `endOffset` to page older history without depending on line
    /// counts, which keeps the cursor stable while new rows are appended.
    public func loadPage(
        endingBefore endOffset: UInt64? = nil,
        limit: Int
    ) throws -> Page {
        try loadPage(endingBefore: endOffset, limit: limit, oversizedRowRecoveryDepth: 0)
    }

    func loadPage(
        endingBefore endOffset: UInt64?,
        limit: Int,
        oversizedRowRecoveryDepth: Int,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> Page {
        guard limit > 0 else {
            return Page(items: [], hasMoreBefore: false, startOffset: nil)
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return Page(items: [], hasMoreBefore: false, startOffset: nil)
        }
        let fh = try FileHandle(forReadingFrom: fileURL)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()
        let pageEnd = min(endOffset ?? fileSize, fileSize)
        guard fileSize > 0, pageEnd > 0 else {
            return Page(items: [], hasMoreBefore: false, startOffset: nil)
        }

        let chunkSize = 64 * 1024
        // Include the terminating newline so a valid row at the byte cap is
        // not mistaken for a partial leading row.
        let maximumTailBytes = Self.maximumPersistedRowBytes + 1
        var offset = pageEnd
        var chunks: [Data] = []
        chunks.reserveCapacity((maximumTailBytes + chunkSize - 1) / chunkSize)
        var totalBytes = 0
        var newlineCount = 0
        while offset > 0 {
            try checkReadDeadline(deadlineNanoseconds)
            let remainingBudget = maximumTailBytes - totalBytes
            guard remainingBudget > 0 else { break }
            let readSize = min(chunkSize, min(remainingBudget, Int(offset)))
            offset -= UInt64(readSize)
            try fh.seek(toOffset: offset)
            guard let chunk = try fh.read(upToCount: readSize), !chunk.isEmpty else {
                break
            }
            try checkReadDeadline(deadlineNanoseconds)
            totalBytes += chunk.count
            newlineCount += chunk.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            chunks.append(chunk)
            if newlineCount > limit {
                break
            }
        }

        try checkReadDeadline(deadlineNanoseconds)
        var tail = Data()
        tail.reserveCapacity(totalBytes)
        for chunk in chunks.reversed() {
            tail.append(chunk)
        }
        try checkReadDeadline(deadlineNanoseconds)
        var lineRanges = lineRanges(in: tail, baseOffset: offset)
        try checkReadDeadline(deadlineNanoseconds)
        // A window that starts away from byte zero may contain only the tail
        // of an oversized unterminated row. Inspect the byte immediately
        // before the window to distinguish that case from an exact row
        // boundary. Treating every range that starts at `offset` as partial
        // would silently drop a valid row at an exact cursor boundary.
        let precedingByte: UInt8?
        if offset > 0 {
            try fh.seek(toOffset: offset - 1)
            precedingByte = try fh.read(upToCount: 1)?.first
        } else {
            precedingByte = nil
        }
        let hasLeadingPartialLine = offset > 0
            && !tail.isEmpty
            && tail.first != 0x0A
            && precedingByte != 0x0A
        if hasLeadingPartialLine, !lineRanges.isEmpty {
            lineRanges.removeFirst()
        }
        let selectedRanges = lineRanges.suffix(limit)
        var out: [WorkstreamItem] = []
        out.reserveCapacity(selectedRanges.count)
        // Decode the whole selection: rows are decoded oldest first, so a
        // cutoff here would leave newer rows that no backward cursor can
        // reach again.
        for lineRange in selectedRanges {
            try checkReadDeadline(deadlineNanoseconds)
            let slice = tail.subdata(in: lineRange.range)
            if slice.count <= Self.maximumPersistedRowBytes,
               let item = try? decoder.decode(WorkstreamItem.self, from: slice) {
                out.append(item)
            }
            // Malformed lines are dropped silently; the audit log is
            // append-only and we don't want a corrupt row to block startup.
        }
        try checkReadDeadline(deadlineNanoseconds)
        var pageStartOffset = selectedRanges.first?.startOffset
        let windowEndsWithNewline: Bool
        if pageEnd > 0 {
            try fh.seek(toOffset: pageEnd - 1)
            windowEndsWithNewline = try fh.read(upToCount: 1)?.first == 0x0A
        } else {
            windowEndsWithNewline = false
        }
        if hasLeadingPartialLine,
           out.count < limit,
           (pageEnd < fileSize || windowEndsWithNewline),
           let result = try previousLineBoundary(before: offset, fileHandle: fh, deadlineNanoseconds: deadlineNanoseconds) {
            // The window starts inside a row. Only a row over the persisted
            // cap is skipped here. An ordinary row that merely straddles the
            // window edge keeps the first complete row as the cursor, so the
            // next page reads the cut row whole instead of losing it.
            let cutRowBytesInWindow = UInt64(tail.firstIndex(of: 0x0A) ?? tail.count)
            let cutRowStartIsKnown = result.foundNewline || result.offset == 0
            let cutRowIsOversized = !cutRowStartIsKnown
                || (offset - result.offset) + cutRowBytesInWindow > UInt64(Self.maximumPersistedRowBytes)
            if !cutRowIsOversized, pageStartOffset == nil, let newline = tail.firstIndex(of: 0x0A) {
                // Nothing complete followed the cut row in this window. Page
                // from just past its newline so the next page reads it whole.
                pageStartOffset = offset + UInt64(newline) + 1
            }
            if cutRowIsOversized {
                // Continue the backward walk from the newline before the
                // oversized row, discarding its bytes instead of buffering
                // them, so older valid rows remain reachable in the same page.
                if result.foundNewline, oversizedRowRecoveryDepth == 0 {
                    let older = try loadPage(
                        endingBefore: result.offset,
                        limit: max(1, limit - out.count),
                        oversizedRowRecoveryDepth: oversizedRowRecoveryDepth + 1,
                        deadlineNanoseconds: deadlineNanoseconds
                    )
                    out = older.items + out
                    pageStartOffset = older.startOffset ?? result.offset
                } else {
                    pageStartOffset = result.offset > 0
                        ? result.offset
                        : (pageStartOffset ?? offset)
                }
            }
        }
        // If the bounded window begins in the middle of an oversized row,
        // the first complete row is not a safe cursor: paging before it can
        // land in the same corrupt row and hide older valid history. The
        // window boundary lets the caller walk backwards in bounded chunks.
        let startOffset = pageStartOffset ?? (offset > 0 ? offset : nil)
        return Page(
            items: out,
            hasMoreBefore: (startOffset ?? 0) > 0,
            startOffset: startOffset
        )
    }

    private struct BackwardScanResult {
        let offset: UInt64
        let foundNewline: Bool
    }

    private func previousLineBoundary(
        before offset: UInt64,
        fileHandle: FileHandle,
        deadlineNanoseconds: UInt64?
    ) throws -> BackwardScanResult? {
        var cursor = offset
        let chunkSize = 64 * 1024
        while cursor > 0, offset - cursor < UInt64(Self.maximumOversizedRowScanBytes) {
            try checkReadDeadline(deadlineNanoseconds)
            let readSize = min(chunkSize, Int(cursor))
            guard readSize > 0 else { break }
            let start = cursor - UInt64(readSize)
            try fileHandle.seek(toOffset: start)
            guard let chunk = try fileHandle.read(upToCount: readSize), !chunk.isEmpty else {
                break
            }
            try checkReadDeadline(deadlineNanoseconds)
            if let index = chunk.lastIndex(of: 0x0A) {
                return BackwardScanResult(offset: start + UInt64(index) + 1, foundNewline: true)
            }
            cursor = start
        }
        return cursor < offset
            ? BackwardScanResult(offset: cursor, foundNewline: false)
            : nil
    }

    /// No further reads or decoding may start after the recovery deadline.
    private func checkReadDeadline(_ deadline: UInt64?) throws {
        if let deadline, uptimeNanoseconds() >= deadline { throw WorkstreamReadDeadline.exceeded }
    }

    func lineRanges(
        in data: Data,
        baseOffset: UInt64
    ) -> [(range: Range<Int>, startOffset: UInt64)] {
        var ranges: [(range: Range<Int>, startOffset: UInt64)] = []
        ranges.reserveCapacity(128)
        var lineStart = 0
        for (idx, byte) in data.enumerated() {
            guard byte == 0x0A else { continue }
            if lineStart < idx {
                ranges.append(
                    (
                        range: lineStart..<idx,
                        startOffset: baseOffset + UInt64(lineStart)
                    )
                )
            }
            lineStart = idx + 1
        }
        if lineStart < data.count {
            ranges.append(
                (
                    range: lineStart..<data.count,
                    startOffset: baseOffset + UInt64(lineStart)
                )
            )
        }
        return ranges
    }
}
