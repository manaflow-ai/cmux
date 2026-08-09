public import Foundation

/// Actor-isolated, retention-bounded JSONL persistence for recorded History events.
public actor VaultHistoryEventStore: VaultHistoryEventStoring {
    private let fileURL: URL?
    private let retention: VaultHistoryRetentionPolicy
    private let fileManager: FileManager
    private var didLoad = false
    private var events: [VaultHistoryEvent] = []
    private var fileBytes = 0

    /// Creates a store backed by one JSONL file or by bounded memory when `fileURL` is `nil`.
    ///
    /// - Parameters:
    ///   - fileURL: JSONL file location, or `nil` for an in-memory store.
    ///   - retention: Memory, file, and load bounds.
    ///   - fileManager: Filesystem dependency used for creation and inspection.
    public init(
        fileURL: URL?,
        retention: VaultHistoryRetentionPolicy = .default,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.retention = retention
        self.fileManager = fileManager
    }

    /// Persists one event and adds it to the in-memory snapshot only after acceptance.
    ///
    /// - Parameter event: Immutable event to append.
    /// - Returns: `true` when the event was accepted by memory-only storage or persisted.
    public func append(_ event: VaultHistoryEvent) async -> Bool {
        loadIfNeeded()
        if let fileURL {
            guard let line = encodedLine(for: event), appendLine(line, to: fileURL) else {
                return false
            }
            fileBytes += line.count
        }

        events.append(event)
        trimMemoryIfNeeded()
        if let fileURL, fileBytes > retention.maxFileBytes {
            compact(to: fileURL)
        }
        return true
    }

    /// Returns the newest recorded events in deterministic order.
    ///
    /// - Parameter limit: Maximum number of events returned.
    /// - Returns: Events ordered by timestamp and stable identifier, newest first.
    public func recentEvents(limit: Int = .max) async -> [VaultHistoryEvent] {
        loadIfNeeded()
        let sortedEvents = events.sorted(by: VaultHistoryEvent.newestFirst)
        guard limit < sortedEvents.count else {
            return sortedEvents
        }
        return Array(sortedEvents.prefix(max(0, limit)))
    }

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

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let fileURL,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()).map(Int.init) ?? 0
        fileBytes = fileSize
        guard fileSize > 0 else { return }

        let readBytes = min(fileSize, retention.maxLoadBytes)
        let startOffset = UInt64(fileSize - readBytes)
        try? handle.seek(toOffset: startOffset)
        guard var data = try? handle.read(upToCount: readBytes) else { return }

        if startOffset > 0, let firstNewline = data.firstIndex(of: 0x0a) {
            data = data[data.index(after: firstNewline)...]
        }

        let decoder = Self.makeDecoder()
        var loadedEvents: [VaultHistoryEvent] = []
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0a) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            lineStart = lineEnd < data.endIndex
                ? data.index(after: lineEnd)
                : data.endIndex
            guard !line.isEmpty,
                  let event = try? decoder.decode(VaultHistoryEvent.self, from: Data(line)) else {
                continue
            }
            loadedEvents.append(event)
        }
        if loadedEvents.count > retention.maxStoredEvents {
            loadedEvents.removeFirst(loadedEvents.count - retention.maxStoredEvents)
        }
        events = loadedEvents
    }

    private func encodedLine(for event: VaultHistoryEvent) -> Data? {
        guard var data = try? Self.makeEncoder().encode(event) else {
            return nil
        }
        data.append(0x0a)
        return data
    }

    private func appendLine(_ line: Data, to fileURL: URL) -> Bool {
        if !fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try line.write(to: fileURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return false
        }
        defer { try? handle.close() }
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }

    private func compact(to fileURL: URL) {
        let encoder = Self.makeEncoder()
        var data = Data()
        for event in events {
            guard let encoded = try? encoder.encode(event) else { continue }
            data.append(encoded)
            data.append(0x0a)
        }
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else {
            return
        }
        fileBytes = data.count
    }

    private func trimMemoryIfNeeded() {
        guard events.count > retention.maxStoredEvents else { return }
        events.removeFirst(events.count - retention.maxStoredEvents)
    }
}
