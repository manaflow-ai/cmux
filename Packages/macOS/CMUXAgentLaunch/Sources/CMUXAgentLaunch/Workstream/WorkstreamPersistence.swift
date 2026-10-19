import Foundation

/// JSONL persistence for `WorkstreamItem`. One item per line. Startup reads
/// remain bounded even if an older build left an oversized append-only log.
///
/// Writes are serialized through an actor so the store can fire them off
/// without awaiting disk IO; reads happen on the caller's executor since
/// load runs once per process at launch.
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

    private let fileURL: URL
    private let revisionURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var handle: FileHandle?

    /// A malformed append-only row must not turn startup into an unbounded
    /// JSON decode. Larger rows are treated as corrupt history by bounded
    /// readers and remain available for later forensic inspection.
    private static let maximumPersistedRowBytes = 8 * 1024 * 1024
    /// Leave one representable value for the startup bump after restoring a
    /// persisted high-water mark.
    private static let maximumRevision = UInt64(Int.max - 1)

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.revisionURL = fileURL.appendingPathExtension("revision")
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
    }

    private func loadBoundedLatest(
        limit: Int,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> BoundedLatestResult {
        guard limit > 0, FileManager.default.fileExists(atPath: fileURL.path) else {
            return BoundedLatestResult(items: [], exceededBudget: false)
        }
        let tail = try readTail(limit: limit, deadlineNanoseconds: deadlineNanoseconds)
        var latestByID: [UUID: (sequence: Int, item: WorkstreamItem)] = [:]
        for (sequence, line) in tail.lines.enumerated().reversed() {
            if let deadlineNanoseconds,
               DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds {
                return BoundedLatestResult(
                    items: latestByID.values.sorted { $0.sequence < $1.sequence }.map(\.item),
                    exceededBudget: true
                )
            }
            guard line.count <= Self.maximumPersistedRowBytes,
                  let item = try? decoder.decode(WorkstreamItem.self, from: line) else { continue }
            if latestByID[item.id] == nil { latestByID[item.id] = (sequence, item) }
            if latestByID.count >= limit { break }
        }
        return BoundedLatestResult(
            items: latestByID.values.sorted { $0.sequence < $1.sequence }.map(\.item),
            exceededBudget: tail.exceededBudget
        )
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
                page: Page(items: [], hasMoreBefore: false, startOffset: nil),
                diagnostics: StartupDiagnostics(
                    elapsedNanoseconds: elapsed,
                    fileBytes: size,
                    exceededBudget: true,
                    missingFile: false
                )
            )
        }
        let paged = try loadPage(limit: limit, deadlineNanoseconds: deadline)
        let page = paged.exceededBudget
            ? Page(items: [], hasMoreBefore: false, startOffset: nil)
            : paged.page
        let revision = try loadRevision()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return StartupSnapshot(
            items: latest.items,
            revision: revision,
            page: page,
            diagnostics: StartupDiagnostics(
                elapsedNanoseconds: elapsed,
                fileBytes: size,
                exceededBudget: paged.exceededBudget
                    || budgetNanoseconds.map { elapsed >= $0 } ?? false,
                missingFile: false
            )
        )
    }

    /// Returns a durable generation for the append-only log. The mobile Feed
    /// uses this as its cache validator, so a Mac restart cannot reset the
    /// revision below the phone's last-known snapshot and hide a reply or
    /// resolution behind a stale `feed.changed` event.
    public func loadRevision() throws -> Int {
        let fileRevision = (try? fileSize()) ?? 0
        let durableRevision = loadSidecarRevision()
        return Int(min(max(fileRevision, durableRevision), Self.maximumRevision))
    }

    /// Persists a feed revision high-water mark independently of JSONL rows.
    /// This covers state transitions such as startup recovery and history
    /// paging that change the remote validator without appending an item.
    public func recordRevision(_ revision: Int) throws {
        guard revision > 0 else { return }
        let current = loadSidecarRevision()
        let next = max(current, UInt64(revision))
        guard next > current else { return }
        let data = Data(String(next).utf8)
        try FileManager.default.createDirectory(
            at: revisionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: revisionURL, options: .atomic)
    }

    private func loadSidecarRevision() -> UInt64 {
        guard let data = FileManager.default.contents(atPath: revisionURL.path),
              let text = String(data: data, encoding: .utf8),
              let value = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return min(value, Self.maximumRevision)
    }

    private struct Tail {
        let lines: [Data]
        let exceededBudget: Bool
    }

    private func readTail(
        limit: Int,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> Tail {
        guard limit > 0, FileManager.default.fileExists(atPath: fileURL.path) else {
            return Tail(lines: [], exceededBudget: false)
        }
        let fh = try FileHandle(forReadingFrom: fileURL)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()
        guard fileSize > 0 else { return Tail(lines: [], exceededBudget: false) }
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
        var lines = data.split(separator: 0x0A).map(Data.init)
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
        if hasLeadingPartialLine, !lines.isEmpty {
            lines.removeFirst()
        }
        return Tail(lines: lines, exceededBudget: exceededBudget)
    }

    /// Loads up to `limit` items ending before `endOffset`. Order in the
    /// returned array is oldest-first. `startOffset` can be passed back
    /// as `endOffset` to page older history without depending on line
    /// counts, which keeps the cursor stable while new rows are appended.
    public func loadPage(
        endingBefore endOffset: UInt64? = nil,
        limit: Int
    ) throws -> Page {
        try loadPage(
            endingBefore: endOffset,
            limit: limit,
            deadlineNanoseconds: nil
        ).page
    }

    private func loadPage(
        endingBefore endOffset: UInt64? = nil,
        limit: Int,
        deadlineNanoseconds: UInt64?
    ) throws -> (page: Page, exceededBudget: Bool) {
        guard limit > 0 else {
            return (Page(items: [], hasMoreBefore: false, startOffset: nil), false)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return (Page(items: [], hasMoreBefore: false, startOffset: nil), false)
        }
        let fh = try FileHandle(forReadingFrom: fileURL)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()
        let pageEnd = min(endOffset ?? fileSize, fileSize)
        guard fileSize > 0, pageEnd > 0 else {
            return (Page(items: [], hasMoreBefore: false, startOffset: nil), false)
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
        var exceededBudget = false
        while offset > 0 {
            if let deadlineNanoseconds,
               DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds {
                exceededBudget = true
                break
            }
            let remainingBudget = maximumTailBytes - totalBytes
            guard remainingBudget > 0 else { break }
            let readSize = min(chunkSize, min(remainingBudget, Int(offset)))
            offset -= UInt64(readSize)
            try fh.seek(toOffset: offset)
            guard let chunk = try fh.read(upToCount: readSize), !chunk.isEmpty else {
                break
            }
            totalBytes += chunk.count
            newlineCount += chunk.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            chunks.append(chunk)
            if newlineCount > limit {
                break
            }
        }

        var tail = Data()
        tail.reserveCapacity(totalBytes)
        for chunk in chunks.reversed() {
            tail.append(chunk)
        }
        var lineRanges = Self.lineRanges(in: tail, baseOffset: offset)
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
        for lineRange in selectedRanges {
            if let deadlineNanoseconds,
               DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds {
                exceededBudget = true
                break
            }
            let slice = tail.subdata(in: lineRange.range)
            if slice.count <= Self.maximumPersistedRowBytes,
               let item = try? decoder.decode(WorkstreamItem.self, from: slice) {
                out.append(item)
            }
            // Malformed lines are dropped silently; the audit log is
            // append-only and we don't want a corrupt row to block startup.
        }
        let selectedStartOffset = selectedRanges.first?.startOffset
        // If the bounded window begins in the middle of an oversized row,
        // the first complete row is not a safe cursor: paging before it can
        // land in the same corrupt row and hide older valid history. The
        // window boundary lets the caller walk backwards in bounded chunks.
        let startOffset = selectedStartOffset ?? (offset > 0 ? offset : nil)
        return (
            Page(
                items: out,
                hasMoreBefore: (startOffset ?? 0) > 0,
                startOffset: startOffset
            ),
            exceededBudget
        )
    }

    /// Truncates the JSONL file. Used by `cmux feed clear`.
    public func clear() throws {
        // The byte count is part of the legacy revision fallback. Snapshot it
        // into the durable sidecar before deleting the log, otherwise a clear
        // after a byte-heavy run could make the next process advertise a
        // generation lower than a subscribed phone has already observed.
        let revisionFloor = try loadRevision()
        try recordRevision(revisionFloor)
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

    private func fileSize() throws -> UInt64 {
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

    private static func lineRanges(
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
