import Foundation

public let WorkstreamDefaultPersistedItemLimit = 100
public let WorkstreamDefaultPersistedByteLimit = 2 * 1024 * 1024
public let WorkstreamDefaultLegacyReadByteLimit = 8 * 1024 * 1024

/// Bounded restart recovery for pending Feed decisions.
///
/// The file remains JSONL for backward compatibility, but it is now an atomic
/// snapshot instead of an append-only activity log. Every write keeps pending
/// actionable items only, caps both row count and encoded bytes, and removes
/// the legacy tombstone sidecar.
public actor WorkstreamPersistence {
    private let fileURL: URL
    private let removedItemsFileURL: URL
    private let maximumItemCount: Int
    private let maximumFileBytes: Int
    private let maximumLegacyReadBytes: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var latestGeneration: UInt64 = 0

    public init(
        fileURL: URL,
        maximumItemCount: Int = WorkstreamDefaultPersistedItemLimit,
        maximumFileBytes: Int = WorkstreamDefaultPersistedByteLimit,
        maximumLegacyReadBytes: Int = WorkstreamDefaultLegacyReadByteLimit
    ) {
        self.fileURL = fileURL
        self.removedItemsFileURL = Self.removedItemsFileURL(for: fileURL)
        self.maximumItemCount = max(0, maximumItemCount)
        self.maximumFileBytes = max(0, maximumFileBytes)
        self.maximumLegacyReadBytes = max(0, maximumLegacyReadBytes)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Default snapshot path in the user's cmuxterm state directory.
    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("workstream.jsonl", isDirectory: false)
    }

    /// Legacy removal log path, retained only so migration can delete it.
    public static func removedItemsFileURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("removed.jsonl")
    }

    /// Loads pending actionable rows from the bounded tail of either the new
    /// snapshot or a legacy append-only file. Order is oldest-first.
    public func loadPendingItems(limit: Int) throws -> [WorkstreamItem] {
        guard limit > 0,
              maximumLegacyReadBytes > 0,
              FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let readSize = min(Int(fileSize), maximumLegacyReadBytes)
        guard readSize > 0 else { return [] }
        try handle.seek(toOffset: fileSize - UInt64(readSize))
        guard let tail = try handle.read(upToCount: readSize), !tail.isEmpty else { return [] }

        let removedItemIDs = try loadLegacyRemovedItemIDs()
        let startsMidLine = UInt64(readSize) < fileSize
        var lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines.compactMap { line -> WorkstreamItem? in
            guard let item = try? decoder.decode(WorkstreamItem.self, from: Data(line)),
                  item.kind.isActionable,
                  item.status.isPending,
                  !removedItemIDs.contains(item.id) else { return nil }
            return item.retainedForFeed()
        }
        .suffix(min(limit, maximumItemCount))
        .map { $0 }
    }

    /// Atomically replaces persisted state. Stale asynchronous writes are
    /// ignored by generation so an older snapshot cannot resurrect a decision.
    public func replacePendingItems(
        _ items: [WorkstreamItem],
        generation: UInt64
    ) throws {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation

        let candidates = items
            .filter { $0.kind.isActionable && $0.status.isPending }
            .suffix(maximumItemCount)
            .map { $0.retainedForFeed().redactedForPersistence() }

        var selectedLines: [Data] = []
        var selectedByteCount = 0
        for item in candidates.reversed() {
            var line = try encoder.encode(item)
            line.append(0x0A)
            guard line.count <= maximumFileBytes else { continue }
            guard selectedByteCount + line.count <= maximumFileBytes else { break }
            selectedLines.append(line)
            selectedByteCount += line.count
        }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: removedItemsFileURL)
        guard !selectedLines.isEmpty else {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var snapshot = Data(capacity: selectedByteCount)
        for line in selectedLines.reversed() {
            snapshot.append(line)
        }
        try snapshot.write(to: fileURL, options: .atomic)
    }

    /// Compatibility read used by diagnostics and focused tests.
    public func loadRecent(limit: Int) throws -> [WorkstreamItem] {
        try loadPendingItems(limit: limit)
    }

    /// Removes the snapshot and any legacy tombstones.
    public func clear() throws {
        latestGeneration &+= 1
        for url in [fileURL, removedItemsFileURL] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                let nsError = error as NSError
                guard nsError.domain == NSCocoaErrorDomain,
                      nsError.code == NSFileNoSuchFileError else { throw error }
            }
        }
    }

    private func loadLegacyRemovedItemIDs() throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: removedItemsFileURL.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: removedItemsFileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= maximumLegacyReadBytes else { return [] }
        let data = try Data(contentsOf: removedItemsFileURL)
        return Set(
            String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap { UUID(uuidString: String($0)) }
        )
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
