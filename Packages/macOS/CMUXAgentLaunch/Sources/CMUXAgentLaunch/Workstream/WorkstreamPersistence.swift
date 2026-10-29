import Foundation

/// JSONL persistence for `WorkstreamItem`. One item per line. Startup reads
/// remain bounded even if an older build left an oversized append-only log.
///
/// Writes are serialized through an actor so the store can fire them off
/// without awaiting disk IO. Reads and decoding run on this actor, away
/// from the main-actor store.
public actor WorkstreamPersistence {
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
    let fileManager: FileManager
    private var handle: FileHandle?
    private var clearTask: Task<Void, Error>?
    private let journalLock: WorkstreamJournalFileLock
    let uptimeNanoseconds: @Sendable () -> UInt64

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

    /// Creates a journal owner with a monotonic clock for read deadlines.
    /// - Parameters:
    ///   - fileURL: The journal to read and append.
    ///   - uptimeNanoseconds: Monotonic uptime used to budget recovery work.
    ///   - fileManager: Filesystem adapter used for journal metadata and removal.
    public init(
        fileURL: URL,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        fileManager: FileManager = .default
    ) {
        self.uptimeNanoseconds = uptimeNanoseconds
        self.fileManager = fileManager
        self.fileURL = fileURL
        self.revisionFile = WorkstreamRevisionFile(url: fileURL.appendingPathExtension("revision"), fileManager: fileManager)
        self.journalLock = WorkstreamJournalFileLock(fileURL: fileURL, fileManager: fileManager)
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
    public func append(_ item: WorkstreamItem) async throws {
        // Clearing must save its floor before deleting the journal. Do not let
        // an append land in that journal while the sidecar write is suspended.
        while let clearTask { _ = await clearTask.result }
        let lease = try await journalLock.acquire()
        defer { lease.release() }
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

    private func loadBoundedLatest(
        limit: Int,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> WorkstreamBoundedLatestResult {
        guard limit > 0, fileManager.fileExists(atPath: fileURL.path) else {
            return WorkstreamBoundedLatestResult(items: [], exceededBudget: false, startOffset: nil)
        }
        let tail = try readTail(limit: limit, deadlineNanoseconds: deadlineNanoseconds)
        var latestByID: [UUID: (sequence: Int, item: WorkstreamItem, offset: UInt64)] = [:]
        var oldestExaminedOffset: UInt64?
        for (sequence, line) in tail.lines.enumerated().reversed() {
            if let deadlineNanoseconds,
               uptimeNanoseconds() >= deadlineNanoseconds {
                // Every line from the oldest examined one to the window end
                // is either kept, an older version of a kept item, or
                // unreadable; everything before it stays reachable by
                // paging. With nothing examined yet, page from the window
                // end so the unexamined rows are read again.
                let cursor = latestByID.values.map(\.offset).min()
                    ?? oldestExaminedOffset
                    ?? tail.endOffset
                return WorkstreamBoundedLatestResult(
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
        return WorkstreamBoundedLatestResult(
            items: latestByID.values.sorted { $0.sequence < $1.sequence }.map(\.item),
            exceededBudget: tail.exceededBudget,
            startOffset: latestByID.isEmpty
                ? emptyTailCursor(tail)
                : (latestByID.values.map(\.offset).min() ?? tail.startOffset)
        )
    }

    /// The paging cursor for a startup tail that yielded no item. The window
    /// start can sit inside a row, and paging from there would decode only
    /// that row's head; the first complete line lets the next page read the
    /// cut row whole.
    private func emptyTailCursor(_ tail: WorkstreamJournalTail) -> UInt64? {
        let cursor = tail.lines.first?.offset ?? tail.startOffset
        return cursor > 0 ? cursor : nil
    }

    /// Loads a bounded startup tail without decoding the complete append-only
    /// log. The revision is the maximum of the file-byte generation and the
    /// durable high-water sidecar, so non-writing transitions remain monotonic
    /// across restart.
    func loadStartupSnapshot(
        limit: Int,
        budgetNanoseconds: UInt64? = nil,
        hardBudgetNanoseconds: UInt64? = nil
    ) throws -> WorkstreamStartupSnapshot {
        let started = uptimeNanoseconds()
        guard limit > 0 else {
            let empty = Page(items: [], hasMoreBefore: false, startOffset: nil)
            let fileExists = fileManager.fileExists(atPath: fileURL.path)
            let fileBytes = (try? fileSize()) ?? 0
            let revision = (try? loadRevision()) ?? Int(min(fileBytes, Self.maximumRevision))
            return WorkstreamStartupSnapshot(
                items: [],
                revision: revision,
                page: empty,
                diagnostics: WorkstreamStartupDiagnostics(
                    elapsedNanoseconds: uptimeNanoseconds() - started,
                    fileBytes: fileBytes,
                    exceededBudget: false,
                    missingFile: !fileExists
                )
            )
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let empty = Page(items: [], hasMoreBefore: false, startOffset: nil)
            let revision = (try? loadRevision()) ?? 0
            return WorkstreamStartupSnapshot(
                items: [],
                revision: revision,
                page: empty,
                diagnostics: WorkstreamStartupDiagnostics(
                    elapsedNanoseconds: uptimeNanoseconds() - started,
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
        if latest.exceededBudget || deadline.map({ uptimeNanoseconds() >= $0 }) == true {
            let elapsed = uptimeNanoseconds() - started
            return WorkstreamStartupSnapshot(
                items: latest.items,
                revision: try loadRevision(),
                page: Page(
                    items: latest.items,
                    hasMoreBefore: (latest.startOffset ?? 0) > 0,
                    startOffset: latest.startOffset
                ),
                diagnostics: WorkstreamStartupDiagnostics(
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
        var fallbackExceededBudget = false
        if items.isEmpty, page.hasMoreBefore {
            do {
                let fromEnd = try loadPage(
                    endingBefore: size, limit: limit,
                    oversizedRowRecoveryDepth: 0, deadlineNanoseconds: deadline
                )
                if !fromEnd.items.isEmpty {
                    items = fromEnd.latestItems
                    page = Page(items: items, hasMoreBefore: fromEnd.hasMoreBefore, startOffset: fromEnd.startOffset)
                }
            } catch WorkstreamReadDeadline.exceeded {
                // Aborted fallback publishes nothing from that pass. Restart
                // paging at the original EOF so every unexamined row remains
                // reachable, including a row cut by the last read window.
                items = []
                page = Page(items: [], hasMoreBefore: size > 0, startOffset: size)
                fallbackExceededBudget = true
            }
        }
        let revision = try loadRevision()
        let elapsed = uptimeNanoseconds() - started
        return WorkstreamStartupSnapshot(
            items: items,
            revision: revision,
            page: page,
            diagnostics: WorkstreamStartupDiagnostics(
                elapsedNanoseconds: elapsed,
                fileBytes: size,
                exceededBudget: fallbackExceededBudget || (budgetNanoseconds.map { elapsed >= $0 } ?? false),
                missingFile: false
            )
        )
    }

    /// Truncates the JSONL file. Used by `cmux feed clear`.
    public func clear() async throws {
        if let clearTask {
            try await clearTask.value
            return
        }
        let task = Task {
            defer { clearTask = nil }
            try await clearJournal()
        }
        clearTask = task
        try await task.value
    }

    private func clearJournal() async throws {
        let lease = try await journalLock.acquire()
        defer { lease.release() }
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
            try fileManager.removeItem(at: fileURL)
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
        guard fileManager.fileExists(atPath: fileURL.path) else { return 0 }
        let size = try fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
        return size?.uint64Value ?? 0
    }

    private func handleForWriting() throws -> FileHandle {
        if let handle {
            var pathMetadata = stat()
            var handleMetadata = stat()
            let pathIsCurrent = stat(fileURL.path, &pathMetadata) == 0
                && fstat(handle.fileDescriptor, &handleMetadata) == 0
                && pathMetadata.st_dev == handleMetadata.st_dev
                && pathMetadata.st_ino == handleMetadata.st_ino
            if pathIsCurrent { return handle }
            try handle.close()
            self.handle = nil
        }
        let fm = fileManager
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

private extension WorkstreamItem {
    func redactedForPersistence() -> WorkstreamItem {
        var copy = self
        copy.payload = payload.redactedForPersistence()
        return copy
    }
}

private extension WorkstreamPayload {
    func redactedForPersistence() -> WorkstreamPayload {
        switch self {
        case .permissionRequest(let requestId, let toolName, let toolInputJSON, let pattern):
            return .permissionRequest(
                requestId: requestId,
                toolName: toolName,
                toolInputJSON: WorkstreamPersistenceRedactor.redactToolInputJSON(toolInputJSON),
                pattern: pattern
            )
        case .toolUse(let toolName, let toolInputJSON):
            return .toolUse(
                toolName: toolName,
                toolInputJSON: WorkstreamPersistenceRedactor.redactToolInputJSON(toolInputJSON)
            )
        case .toolResult(let toolName, let resultJSON, let isError):
            return .toolResult(
                toolName: toolName,
                resultJSON: WorkstreamPersistenceRedactor.redactToolInputJSON(resultJSON),
                isError: isError
            )
        default:
            return self
        }
    }
}

private enum WorkstreamPersistenceRedactor {
    private static let sensitiveFragments = [
        "token",
        "secret",
        "password",
        "passwd",
        "api_key",
        "apikey",
        "access_key",
        "private_key",
        "authorization",
        "cookie",
        "credential",
        "env",
    ]

    static func redactToolInputJSON(_ input: String) -> String {
        guard let data = input.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              )
        else {
            return redactString(input)
        }

        let redacted = redactJSONValue(value, key: nil)
        guard JSONSerialization.isValidJSONObject(redacted) || redacted is String
        else { return redactString(input) }
        guard let out = try? JSONSerialization.data(
            withJSONObject: redacted,
            options: [.fragmentsAllowed, .sortedKeys]
        ),
              let string = String(data: out, encoding: .utf8)
        else { return redactString(input) }
        return string
    }

    private static func redactJSONValue(_ value: Any, key: String?) -> Any {
        if let key, isSensitiveKey(key) {
            return "<redacted>"
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = redactJSONValue(v, key: k)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { redactJSONValue($0, key: nil) }
        }
        if let string = value as? String {
            return redactString(string)
        }
        return value
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return sensitiveFragments.contains { normalized.contains($0) }
    }

    private static func redactString(_ string: String) -> String {
        var out = string
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if !homePath.isEmpty {
            out = out.replacingOccurrences(of: homePath, with: "~")
        }
        return redactEnvironmentAssignments(in: out)
    }

    private static func redactEnvironmentAssignments(in string: String) -> String {
        let pattern = #"(?i)\b([A-Z_][A-Z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|AUTHORIZATION|COOKIE|CREDENTIAL)[A-Z0-9_]*)=("[^"]*"|'[^']*'|[^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return string
        }
        var out = string
        let range = NSRange(out.startIndex..<out.endIndex, in: out)
        for match in regex.matches(in: out, range: range).reversed() {
            guard match.numberOfRanges >= 4,
                  let valueRange = Range(match.range(at: 3), in: out)
            else { continue }
            out.replaceSubrange(valueRange, with: "<redacted>")
        }
        return out
    }
}
