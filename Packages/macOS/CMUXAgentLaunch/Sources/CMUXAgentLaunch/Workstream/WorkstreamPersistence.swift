import Foundation

/// JSONL persistence for `WorkstreamItem`. One item per line. Startup reads
/// remain bounded even if an older build left an oversized append-only log.
///
/// Writes are serialized through an actor so the store can fire them off
/// without awaiting disk IO. Reads and decoding run on this actor, away
/// from the main-actor store.
public actor WorkstreamPersistence {
    public struct StartupDiagnostics: Sendable, Equatable {
        public let elapsedNanoseconds: UInt64
        public let fileBytes: UInt64
        public let exceededBudget: Bool
        public let missingFile: Bool

        public init(
            elapsedNanoseconds: UInt64,
            fileBytes: UInt64,
            exceededBudget: Bool,
            missingFile: Bool
        ) {
            self.elapsedNanoseconds = elapsedNanoseconds
            self.fileBytes = fileBytes
            self.exceededBudget = exceededBudget
            self.missingFile = missingFile
        }
    }

    /// The startup state loaded without scanning the complete log.
    public struct StartupSnapshot: Sendable {
        public let items: [WorkstreamItem]
        public let revision: Int
        public let page: Page
        public let diagnostics: StartupDiagnostics

        public init(
            items: [WorkstreamItem],
            revision: Int,
            page: Page,
            diagnostics: StartupDiagnostics = StartupDiagnostics(
                elapsedNanoseconds: 0,
                fileBytes: 0,
                exceededBudget: false,
                missingFile: false
            )
        ) {
            self.items = items
            self.revision = revision
            self.page = page
            self.diagnostics = diagnostics
        }
    }

    public struct Page: Sendable, Equatable {
        public let items: [WorkstreamItem]
        public let hasMoreBefore: Bool
        public let startOffset: UInt64?

        public init(
            items: [WorkstreamItem],
            hasMoreBefore: Bool,
            startOffset: UInt64?
        ) {
            self.items = items
            self.hasMoreBefore = hasMoreBefore
            self.startOffset = startOffset
        }
    }

    let fileURL: URL
    let revisionFile: WorkstreamRevisionFile
    private let encoder: JSONEncoder
    let decoder: JSONDecoder
    private var handle: FileHandle?

    /// A malformed append-only row must not turn startup into an unbounded
    /// JSON decode. Larger rows are treated as corrupt history by bounded
    /// readers and remain available for later forensic inspection.
    static let maximumPersistedRowBytes = 8 * 1024 * 1024
    /// A backward scan never buffers more than this many bytes from an
    /// oversized row. If no newline is found, the returned progress cursor
    /// advances another bounded chunk and the next page continues the walk.
    static let maximumOversizedRowScanBytes = maximumPersistedRowBytes * 2
    /// Leave one representable value for the startup bump after restoring a
    /// persisted high-water mark.
    static let maximumRevision = UInt64(Int.max - 1)

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.revisionFile = WorkstreamRevisionFile(url: fileURL.appendingPathExtension("revision"))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Default JSONL path in the user's cmuxterm state directory.
    public static func defaultFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("workstream.jsonl", isDirectory: false)
    }

    /// Appends a single item as a JSON line. Creates the file and parent
    /// directory lazily on first write.
    public func append(_ item: WorkstreamItem) throws {
        let data = try encoder.encode(item.redactedForPersistence())
        var line = data
        line.append(0x0A) // "\n"
        let fh = try handleForWriting()
        try repairTornTrailingRow(in: fh)
        try fh.seekToEnd()
        try fh.write(contentsOf: line)
    }

    /// Loads the last `limit` items from the file. Order in the returned
    /// array is oldest-first. Missing file returns empty.
    public func loadRecent(limit: Int) throws -> [WorkstreamItem] {
        try loadPage(endingBefore: nil, limit: limit).items
    }

    /// Loads the newest durable versions found in a bounded recovery tail.
    /// Mutations are written as additional JSONL rows, so startup collapses
    /// duplicate IDs in that tail before publishing state. Very old rows
    /// beyond the recovery bound are available through ``loadPage``.
    public func loadLatest(limit: Int) throws -> [WorkstreamItem] {
        try loadBoundedLatest(limit: limit).items
    }

    private struct BoundedLatestResult {
        let items: [WorkstreamItem]
        let exceededBudget: Bool
        let startOffset: UInt64?
    }

    private func loadBoundedLatest(
        limit: Int,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> BoundedLatestResult {
        guard limit > 0, FileManager.default.fileExists(atPath: fileURL.path) else {
            return BoundedLatestResult(items: [], exceededBudget: false, startOffset: nil)
        }
        let tail = try readTail(limit: limit, deadlineNanoseconds: deadlineNanoseconds)
        var latestByID: [UUID: (sequence: Int, item: WorkstreamItem, offset: UInt64)] = [:]
        var oldestExaminedOffset: UInt64?
        for (sequence, line) in tail.lines.enumerated().reversed() {
            if let deadlineNanoseconds,
               DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds {
                // Every line from the oldest examined one to the window end
                // is either kept, an older version of a kept item, or
                // unreadable; everything before it stays reachable by
                // paging. With nothing examined yet, page from the window
                // end so the unexamined rows are read again.
                let cursor = latestByID.values.map(\.offset).min()
                    ?? oldestExaminedOffset
                    ?? tail.endOffset
                return BoundedLatestResult(
                    items: latestByID.values.sorted { $0.sequence < $1.sequence }.map(\.item),
                    exceededBudget: true,
                    startOffset: cursor > 0 ? cursor : nil
                )
            }
            oldestExaminedOffset = line.offset
            guard line.data.count <= Self.maximumPersistedRowBytes,
                  let item = try? decoder.decode(WorkstreamItem.self, from: line.data) else { continue }
            if latestByID[item.id] == nil { latestByID[item.id] = (sequence, item, line.offset) }
            if latestByID.count >= limit { break }
        }
        return BoundedLatestResult(
            items: latestByID.values.sorted { $0.sequence < $1.sequence }.map(\.item),
            exceededBudget: tail.exceededBudget,
            startOffset: latestByID.isEmpty
                ? Self.emptyTailCursor(tail)
                : (latestByID.values.map(\.offset).min() ?? tail.startOffset)
        )
    }

    /// The paging cursor for a startup tail that yielded no item. The window
    /// start can sit inside a row, and paging from there would decode only
    /// that row's head; the first complete line lets the next page read the
    /// cut row whole.
    private static func emptyTailCursor(_ tail: Tail) -> UInt64? {
        let cursor = tail.lines.first?.offset ?? tail.startOffset
        return cursor > 0 ? cursor : nil
    }

    /// Loads a bounded startup tail without decoding the complete append-only
    /// log. The revision is the maximum of the file-byte generation and the
    /// durable high-water sidecar, so non-writing transitions remain monotonic
    /// across restart.
    public func loadStartupSnapshot(
        limit: Int,
        budgetNanoseconds: UInt64? = nil,
        hardBudgetNanoseconds: UInt64? = nil
    ) throws -> StartupSnapshot {
        let started = DispatchTime.now().uptimeNanoseconds
        guard limit > 0 else {
            let empty = Page(items: [], hasMoreBefore: false, startOffset: nil)
            let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
            let fileBytes = (try? fileSize()) ?? 0
            let revision = (try? loadRevision()) ?? Int(min(fileBytes, Self.maximumRevision))
            return StartupSnapshot(
                items: [],
                revision: revision,
                page: empty,
                diagnostics: StartupDiagnostics(
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                    fileBytes: fileBytes,
                    exceededBudget: false,
                    missingFile: !fileExists
                )
            )
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = Page(items: [], hasMoreBefore: false, startOffset: nil)
            let revision = (try? loadRevision()) ?? 0
            return StartupSnapshot(
                items: [],
                revision: revision,
                page: empty,
                diagnostics: StartupDiagnostics(
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                    fileBytes: 0,
                    exceededBudget: false,
                    missingFile: true
                )
            )
        }
        let size = try fileSize()
        let deadline = hardBudgetNanoseconds.map { budget in
            let (deadline, overflow) = started.addingReportingOverflow(budget)
            return overflow ? UInt64.max : deadline
        }
        let latest = try loadBoundedLatest(
            limit: limit,
            deadlineNanoseconds: deadline
        )
        if latest.exceededBudget || deadline.map({ DispatchTime.now().uptimeNanoseconds >= $0 }) == true {
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            return StartupSnapshot(
                items: latest.items,
                revision: try loadRevision(),
                page: Page(
                    items: latest.items,
                    hasMoreBefore: (latest.startOffset ?? 0) > 0,
                    startOffset: latest.startOffset
                ),
                diagnostics: StartupDiagnostics(
                    elapsedNanoseconds: elapsed,
                    fileBytes: size,
                    exceededBudget: true,
                    missingFile: false
                )
            )
        }
        // The items come from the bounded tail, so the cursor must as well.
        // A separate paging pass could reach further back than these items
        // and leave the rows in between unreachable.
        var items = latest.items
        var page = Page(
            items: latest.items,
            hasMoreBefore: (latest.startOffset ?? 0) > 0,
            startOffset: latest.startOffset
        )
        if items.isEmpty, page.hasMoreBefore {
            // The newest row can be larger than the tail window, which then
            // holds no complete row. Paging from the end skips an oversized
            // complete row and reaches the history before it; keep the empty
            // result when even that finds nothing (an unterminated tail).
            let fromEnd = try loadPage(
                endingBefore: nil,
                limit: limit,
                deadlineNanoseconds: deadline
            )
            if !fromEnd.items.isEmpty {
                let latest = fromEnd.latestItems
                items = latest
                page = Page(
                    items: latest,
                    hasMoreBefore: fromEnd.hasMoreBefore,
                    startOffset: fromEnd.startOffset
                )
            }
        }
        let revision = try loadRevision()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return StartupSnapshot(
            items: items,
            revision: revision,
            page: page,
            diagnostics: StartupDiagnostics(
                elapsedNanoseconds: elapsed,
                fileBytes: size,
                exceededBudget: budgetNanoseconds.map { elapsed >= $0 } ?? false,
                missingFile: false
            )
        )
    }

    private struct Tail {
        struct Line {
            let data: Data
            let offset: UInt64
        }
        let lines: [Line]
        let exceededBudget: Bool
        let startOffset: UInt64
        /// The file size when the window was read, which is where it ends.
        let endOffset: UInt64
    }

    private func readTail(
        limit: Int,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> Tail {
        guard limit > 0, FileManager.default.fileExists(atPath: fileURL.path) else {
            return Tail(lines: [], exceededBudget: false, startOffset: 0, endOffset: 0)
        }
        let fh = try FileHandle(forReadingFrom: fileURL)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()
        guard fileSize > 0 else { return Tail(lines: [], exceededBudget: false, startOffset: 0, endOffset: 0) }
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
               DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds {
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
        var lineRanges = Self.lineRanges(in: data, baseOffset: offset)
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
            Tail.Line(data: data.subdata(in: range.range), offset: range.startOffset)
        }
        return Tail(
            lines: lines,
            exceededBudget: exceededBudget,
            startOffset: offset,
            endOffset: fileSize
        )
    }

    /// Truncates the JSONL file. Used by `cmux feed clear`.
    public func clear() async throws {
        // The byte count is part of the legacy revision fallback. Snapshot it
        // into the durable sidecar before deleting the log, otherwise a clear
        // after a byte-heavy run could make the next process advertise a
        // generation lower than a subscribed phone has already observed.
        let revisionFloor = try loadRevision()
        try await recordRevision(revisionFloor)
        if let fh = handle {
            try fh.close()
        }
        handle = nil
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileNoSuchFileError {
                // The revision sidecar is intentionally preserved below.
            } else {
                throw error
            }
        }
        // Keep the revision sidecar. Clearing visible history must not let a
        // subscribed phone observe a lower generation after the next launch.
    }

    func fileSize() throws -> UInt64 {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
        let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
        return size?.uint64Value ?? 0
    }

    private func handleForWriting() throws -> FileHandle {
        if let handle { return handle }
        let fm = FileManager.default
        try fm.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        // Read access is required to detect and truncate a crash-torn final
        // row before the next append.
        let fh = try FileHandle(forUpdating: fileURL)
        handle = fh
        return fh
    }

    /// A crash can leave the final JSONL row without its newline. Appending
    /// directly would concatenate the next object onto that invalid row and
    /// make the new event invisible to bounded readers. Repair only the
    /// trailing incomplete row. Preserve the bytes for forensic recovery and
    /// insert a separator so the next valid JSON object remains readable.
    private func repairTornTrailingRow(in fh: FileHandle) throws {
        let end = try fh.seekToEnd()
        guard end > 0 else { return }
        try fh.seek(toOffset: end - 1)
        guard let lastByte = try fh.read(upToCount: 1)?.first,
              lastByte != 0x0A else { return }

        try fh.seekToEnd()
        try fh.write(contentsOf: Data([0x0A]))
    }


}
