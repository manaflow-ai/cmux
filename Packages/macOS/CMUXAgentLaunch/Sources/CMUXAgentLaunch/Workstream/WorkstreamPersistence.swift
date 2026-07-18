import Foundation

/// Append-only JSONL persistence for `WorkstreamItem`. One item per line,
/// unbounded on disk. The in-memory ring buffer on `WorkstreamStore` is
/// the only cap on working set size; this layer exists for restart
/// recovery and long-term audit.
///
/// Writes are serialized through an actor. Ordinary one-way Feed events may
/// fire writes without awaiting them, while acknowledged events use a bounded
/// SQLite receipt sidecar and return only after their JSONL row is durable.
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

    private let fileURL: URL
    private let receiptRetention: TimeInterval
    private let receiptDatabase: WorkstreamReceiptDatabase
    private let clock: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var handle: FileHandle?

    /// Creates JSONL history persistence with a bounded durable receipt sidecar.
    ///
    /// - Parameters:
    ///   - fileURL: Location of the append-only JSONL Feed history.
    ///   - receiptDatabaseURL: SQLite sidecar location. When omitted, a
    ///     `receipts.sqlite3` suffix is appended to `fileURL`.
    ///   - receiptRetention: Sliding window after which an acknowledged request
    ///     receipt becomes reclaimable under storage pressure. A retry refreshes
    ///     the window. Defaults to one day.
    ///   - maximumReceiptCount: Maximum number of live request receipts. New
    ///     identities receive ``WorkstreamPersistenceError/receiptCountLimitReached(maximumCount:)``
    ///     at the bound; retries of existing identities remain available.
    ///   - maximumReceiptStoreBytes: Maximum combined budget for the receipt
    ///     database, WAL, and shared-memory index. New identities receive
    ///     ``WorkstreamPersistenceError/receiptByteLimitReached(maximumBytes:)``
    ///     when SQLite reaches the bound.
    ///   - clock: Clock used for receipt retention and retry liveness.
    public init(
        fileURL: URL,
        receiptDatabaseURL: URL? = nil,
        receiptRetention: TimeInterval = 24 * 60 * 60,
        maximumReceiptCount: Int = 100_000,
        maximumReceiptStoreBytes: Int64 = 64 * 1_024 * 1_024,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(receiptRetention > 0, "receiptRetention must be positive")
        precondition(maximumReceiptCount > 0, "maximumReceiptCount must be positive")
        precondition(maximumReceiptStoreBytes > 0, "maximumReceiptStoreBytes must be positive")
        self.fileURL = fileURL
        let resolvedReceiptDatabaseURL = receiptDatabaseURL
            ?? fileURL.appendingPathExtension("receipts.sqlite3")
        self.receiptRetention = receiptRetention
        self.receiptDatabase = WorkstreamReceiptDatabase(
            url: resolvedReceiptDatabaseURL,
            retention: receiptRetention,
            maximumCount: maximumReceiptCount,
            maximumBytes: maximumReceiptStoreBytes
        )
        self.clock = clock
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
        try appendHistoryLine(item, synchronize: false)
    }

    /// Durably appends one acknowledged Feed item exactly once for its request identity.
    ///
    /// Identity is the collision-free tuple of event source, session identifier,
    /// hook event name, and request identifier. The method first commits a stable
    /// item UUID to the SQLite receipt sidecar, then synchronizes the JSONL append,
    /// and finally marks the receipt appended. A retry returns the same UUID. If a
    /// process stopped after the JSONL append but before the final mark, recovery
    /// finds that UUID anywhere in JSONL and completes the receipt without appending
    /// a second row.
    ///
    /// - Parameters:
    ///   - item: Candidate history item. Its UUID is replaced by the stable receipt UUID.
    ///   - event: Wire event supplying the durable composite request identity.
    /// - Returns: The stable UUID used by the receipt and JSONL history row.
    /// - Throws: ``WorkstreamPersistenceError`` for invalid identities or explicit
    ///   receipt backpressure, plus filesystem or SQLite errors when persistence fails.
    public func appendAcknowledged(
        _ item: WorkstreamItem,
        for event: WorkstreamEvent
    ) throws -> UUID {
        guard let requestID = event.requestId,
              !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw WorkstreamPersistenceError.missingRequestIdentity
        }

        let now = clock().timeIntervalSince1970
        let receipt = try receiptDatabase.reserve(
            source: event.source,
            sessionID: event.sessionId,
            eventName: event.hookEventName.rawValue,
            requestID: requestID,
            now: now
        )
        if receipt.appended {
            return receipt.itemID
        }

        let persistedItem = item.replacingID(receipt.itemID)
        let delayedBeyondReceiptRetention = now - event.receivedAt.timeIntervalSince1970
            >= receiptRetention
        if (receipt.existedBeforeReservation || delayedBeyondReceiptRetention),
           try historyContainsItem(withID: receipt.itemID) {
            try receiptDatabase.markAppended(
                source: event.source,
                sessionID: event.sessionId,
                eventName: event.hookEventName.rawValue,
                requestID: requestID,
                itemID: receipt.itemID,
                now: now
            )
            return receipt.itemID
        }

        try appendHistoryLine(persistedItem, synchronize: true)
        try receiptDatabase.markAppended(
            source: event.source,
            sessionID: event.sessionId,
            eventName: event.hookEventName.rawValue,
            requestID: requestID,
            itemID: receipt.itemID,
            now: now
        )
        return receipt.itemID
    }

    private func appendHistoryLine(
        _ item: WorkstreamItem,
        synchronize: Bool
    ) throws {
        let data = try encoder.encode(item.redactedForPersistence())
        var line = data
        line.append(0x0A) // "\n"
        let fh = try handleForWriting()
        let endOffset = try fh.seekToEnd()
        if endOffset > 0 {
            try fh.seek(toOffset: endOffset - 1)
            let finalByte = try fh.read(upToCount: 1)?.first
            if finalByte != 0x0A {
                try fh.seekToEnd()
                try fh.write(contentsOf: Data([0x0A]))
            }
        }
        try fh.write(contentsOf: line)
        if synchronize {
            try fh.synchronize()
        }
    }

    /// Loads the last `limit` items from the file. Order in the returned
    /// array is oldest-first. Missing file returns empty.
    public func loadRecent(limit: Int) throws -> [WorkstreamItem] {
        try loadPage(endingBefore: nil, limit: limit).items
    }

    /// Loads up to `limit` items ending before `endOffset`. Order in the
    /// returned array is oldest-first. `startOffset` can be passed back
    /// as `endOffset` to page older history without depending on line
    /// counts, which keeps the cursor stable while new rows are appended.
    public func loadPage(
        endingBefore endOffset: UInt64? = nil,
        limit: Int
    ) throws -> Page {
        guard limit > 0 else {
            return Page(items: [], hasMoreBefore: false, startOffset: nil)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
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
        var offset = pageEnd
        var tail = Data()
        var lineRanges: [(range: Range<Int>, startOffset: UInt64)] = []
        while offset > 0 {
            let readSize = min(chunkSize, Int(offset))
            offset -= UInt64(readSize)
            try fh.seek(toOffset: offset)
            guard let chunk = try fh.read(upToCount: readSize), !chunk.isEmpty else {
                break
            }
            tail.insert(contentsOf: chunk, at: 0)
            lineRanges = Self.lineRanges(in: tail, baseOffset: offset)
            if lineRanges.count > limit {
                break
            }
        }

        if lineRanges.isEmpty {
            lineRanges = Self.lineRanges(in: tail, baseOffset: offset)
        }
        let selectedRanges = lineRanges.suffix(limit)
        var decoded: [WorkstreamItem] = []
        decoded.reserveCapacity(selectedRanges.count)
        for lineRange in selectedRanges {
            let slice = tail.subdata(in: lineRange.range)
            if let item = try? decoder.decode(WorkstreamItem.self, from: slice) {
                decoded.append(item)
            }
            // Malformed lines are dropped silently; the audit log is
            // append-only and we don't want a corrupt row to block startup.
        }
        var seenIDs = Set<UUID>()
        let out = decoded.reversed().filter { seenIDs.insert($0.id).inserted }.reversed()
        let startOffset = selectedRanges.first?.startOffset
        return Page(
            items: Array(out),
            hasMoreBefore: (startOffset ?? 0) > 0,
            startOffset: startOffset
        )
    }

    /// Truncates the JSONL file. Used by `cmux feed clear`.
    public func clear() throws {
        if let fh = handle {
            try fh.close()
        }
        handle = nil
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                let nsError = error as NSError
                guard nsError.domain == NSCocoaErrorDomain,
                      nsError.code == NSFileNoSuchFileError
                else { throw error }
            }
        }
        try receiptDatabase.clearIfPresent()
    }

    private func historyContainsItem(withID itemID: UUID) throws -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        let readHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? readHandle.close() }

        var pending = Data()
        while let chunk = try readHandle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                if historyLine(line, hasID: itemID) { return true }
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        return !pending.isEmpty && historyLine(pending, hasID: itemID)
    }

    private func historyLine(_ line: Data, hasID itemID: UUID) -> Bool {
        (try? decoder.decode(WorkstreamItem.self, from: line).id) == itemID
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
        let fh = try FileHandle(forUpdating: fileURL)
        handle = fh
        return fh
    }

    private static let sqliteErrorDomain = "CMUXAgentLaunch.WorkstreamPersistence.SQLite"

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
