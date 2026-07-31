import Foundation

/// Append-only persistence for recorded ``VaultHistoryEvent`` values.
///
/// Events are stored one JSON object per line in an append-only file so a
/// crash can lose at most the final partial line. Loading reads a bounded
/// tail (never the whole file), and appends trigger a compacting rewrite
/// once the file passes the retention policy's size threshold, so neither
/// the file nor memory can grow unbounded.
///
/// With a `nil` file URL (automated tests, sandboxed fallback) the store is
/// memory-only but keeps the same bounded behavior.
actor VaultHistoryEventStore {
    private let fileURL: URL?
    private let retention: VaultHistoryRetentionPolicy
    private var didLoad = false
    /// Ascending by append order; bounded by `retention.maxStoredEvents`.
    private var events: [VaultHistoryEvent] = []
    private var fileBytes = 0

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    init(fileURL: URL?, retention: VaultHistoryRetentionPolicy = .default) {
        self.fileURL = fileURL
        self.retention = retention
    }

    /// Appends one event, persisting it and compacting the file if it has
    /// outgrown the retention policy.
    func append(_ event: VaultHistoryEvent) {
        loadIfNeeded()
        events.append(event)
        trimMemoryIfNeeded()
        guard let fileURL else { return }
        guard let line = encodedLine(for: event) else { return }
        if appendLine(line, to: fileURL) {
            fileBytes += line.count
        }
        if fileBytes > retention.maxFileBytes {
            compact(to: fileURL)
        }
    }

    /// Most recent events, newest first, capped at `limit`.
    func recentEvents(limit: Int = Int.max) -> [VaultHistoryEvent] {
        loadIfNeeded()
        let sorted = events.sorted { $0.timestamp > $1.timestamp }
        guard limit < sorted.count else { return sorted }
        return Array(sorted.prefix(limit))
    }

    // MARK: - Load

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let fileURL else { return }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()).map(Int.init) ?? 0
        fileBytes = fileSize
        guard fileSize > 0 else { return }

        let readBytes = min(fileSize, retention.maxLoadBytes)
        let startOffset = UInt64(fileSize - readBytes)
        try? handle.seek(toOffset: startOffset)
        guard var data = try? handle.read(upToCount: readBytes) else { return }

        // A mid-file start lands inside a record: drop up to the first newline.
        if startOffset > 0, let firstNewline = data.firstIndex(of: 0x0a) {
            data = data[data.index(after: firstNewline)...]
        }

        let decoder = Self.makeDecoder()
        var loaded: [VaultHistoryEvent] = []
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0a) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            guard !line.isEmpty else { continue }
            guard let event = try? decoder.decode(VaultHistoryEvent.self, from: Data(line)) else { continue }
            loaded.append(event)
        }
        if loaded.count > retention.maxStoredEvents {
            loaded.removeFirst(loaded.count - retention.maxStoredEvents)
        }
        events = loaded
    }

    // MARK: - Persistence

    private func encodedLine(for event: VaultHistoryEvent) -> Data? {
        guard var data = try? Self.makeEncoder().encode(event) else { return nil }
        data.append(0x0a)
        return data
    }

    private func appendLine(_ line: Data, to fileURL: URL) -> Bool {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return (try? line.write(to: fileURL, options: .atomic)) != nil
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil else { return false }
        return (try? handle.write(contentsOf: line)) != nil
    }

    /// Rewrites the file from the bounded in-memory buffer, dropping history
    /// beyond `retention.maxStoredEvents`.
    private func compact(to fileURL: URL) {
        trimMemoryIfNeeded()
        let encoder = Self.makeEncoder()
        var data = Data()
        for event in events {
            guard let encoded = try? encoder.encode(event) else { continue }
            data.append(encoded)
            data.append(0x0a)
        }
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        fileBytes = data.count
    }

    private func trimMemoryIfNeeded() {
        if events.count > retention.maxStoredEvents {
            events.removeFirst(events.count - retention.maxStoredEvents)
        }
    }
}
