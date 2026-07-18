import Foundation

/// Append-only JSONL persistence for `WorkstreamItem`. One item per line,
/// unbounded on disk. The in-memory ring buffer on `WorkstreamStore` is
/// the only cap on working set size; this layer exists for restart
/// recovery and long-term audit.
///
/// Writes are serialized through an actor so the store can fire them off
/// without awaiting disk IO; reads happen on the caller's executor since
/// load runs once per process at launch.
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
    private let removedItemsFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var handle: FileHandle?
    private var removedItemsHandle: FileHandle?
    private var cachedRemovedItemIDs: Set<UUID>?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.removedItemsFileURL = Self.removedItemsFileURL(for: fileURL)
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

    public static func removedItemsFileURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("removed.jsonl")
    }

    /// Appends a single item as a JSON line. Creates the file and parent
    /// directory lazily on first write.
    public func append(_ item: WorkstreamItem) throws {
        let data = try encoder.encode(item.redactedForPersistence())
        var line = data
        line.append(0x0A) // "\n"
        let fh = try handleForWriting()
        try fh.seekToEnd()
        try fh.write(contentsOf: line)
    }

    /// Persists an item tombstone without rewriting the unbounded event log.
    /// Readers apply tombstones while paging, so user removals survive restart
    /// and existing byte cursors remain stable while new events are appended.
    public func remove(_ itemID: UUID) throws {
        var removedItemIDs = try loadRemovedItemIDs()
        guard removedItemIDs.insert(itemID).inserted else { return }

        var line = Data(itemID.uuidString.utf8)
        line.append(0x0A)
        let fh = try handleForRemovedItemsWriting()
        try fh.seekToEnd()
        try fh.write(contentsOf: line)
        cachedRemovedItemIDs = removedItemIDs
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
        let removedItemIDs = try loadRemovedItemIDs()
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
            if lineRanges.count > limit + removedItemIDs.count {
                break
            }
        }

        if lineRanges.isEmpty {
            lineRanges = Self.lineRanges(in: tail, baseOffset: offset)
        }
        var decoded: [(item: WorkstreamItem, startOffset: UInt64)] = []
        decoded.reserveCapacity(lineRanges.count)
        for lineRange in lineRanges {
            let slice = tail.subdata(in: lineRange.range)
            if let item = try? decoder.decode(WorkstreamItem.self, from: slice),
               !removedItemIDs.contains(item.id) {
                decoded.append((item, lineRange.startOffset))
            }
            // Malformed lines are dropped silently; the audit log is
            // append-only and we don't want a corrupt row to block startup.
        }
        let selected = decoded.suffix(limit)
        let out = selected.map(\.item)
        let startOffset = selected.first?.startOffset
        return Page(
            items: out,
            hasMoreBefore: (startOffset ?? 0) > 0,
            startOffset: startOffset
        )
    }

    /// Truncates the JSONL file. Used by `cmux feed clear`.
    public func clear() throws {
        if let fh = handle {
            try fh.close()
        }
        if let fh = removedItemsHandle {
            try fh.close()
        }
        handle = nil
        removedItemsHandle = nil
        cachedRemovedItemIDs = []
        for url in [fileURL, removedItemsFileURL] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain,
                   nsError.code == NSFileNoSuchFileError {
                    continue
                }
                throw error
            }
        }
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
        let fh = try FileHandle(forWritingTo: fileURL)
        handle = fh
        return fh
    }

    private func handleForRemovedItemsWriting() throws -> FileHandle {
        if let removedItemsHandle { return removedItemsHandle }
        let fm = FileManager.default
        try fm.createDirectory(
            at: removedItemsFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fm.fileExists(atPath: removedItemsFileURL.path) {
            fm.createFile(atPath: removedItemsFileURL.path, contents: nil)
        }
        let fh = try FileHandle(forWritingTo: removedItemsFileURL)
        removedItemsHandle = fh
        return fh
    }

    private func loadRemovedItemIDs() throws -> Set<UUID> {
        if let cachedRemovedItemIDs { return cachedRemovedItemIDs }
        guard FileManager.default.fileExists(atPath: removedItemsFileURL.path) else {
            cachedRemovedItemIDs = []
            return []
        }
        let data = try Data(contentsOf: removedItemsFileURL)
        let removedItemIDs = Set(
            String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap { UUID(uuidString: String($0)) }
        )
        cachedRemovedItemIDs = removedItemIDs
        return removedItemIDs
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

/// Redaction used by persistence and read-only diagnostic projections.
public extension WorkstreamPayload {
    /// Returns a payload whose tool input and result fields are safe to persist
    /// or expose through read-only diagnostic APIs.
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
