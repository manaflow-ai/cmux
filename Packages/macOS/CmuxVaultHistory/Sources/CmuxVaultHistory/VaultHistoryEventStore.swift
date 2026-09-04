public import Foundation

/// Actor-isolated, retention-bounded JSONL persistence for recorded History events.
public actor VaultHistoryEventStore: VaultHistoryEventStoring {
    private let fileURL: URL?
    private let retention: VaultHistoryRetentionPolicy
    private let fileManager: FileManager
    private var didLoad = false
    /// Retention and read order, updated incrementally so refreshes never re-sort.
    private var newestFirstEvents: [VaultHistoryEvent] = []
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

    /// Processes one event through persistence and timestamp-based retention.
    ///
    /// - Parameter event: Immutable event to append.
    /// - Returns: `true` when storage accepted the mutation. An event older
    ///   than the retained timestamp window can be evicted immediately.
    public func append(_ event: VaultHistoryEvent) async -> Bool {
        loadIfNeeded()
        guard let line = encodedLine(for: event), line.count <= retention.maxFileBytes else {
            return false
        }
        if let fileURL {
            let preservesChronologicalFileOrder = newestFirstEvents.first.map {
                VaultHistoryEvent.newestFirst(event, $0)
            } ?? true
            if fileBytes + line.count > retention.maxFileBytes
                || !preservesChronologicalFileOrder {
                let snapshot = compactedSnapshot(including: event)
                guard writeCompactedData(snapshot.data, to: fileURL) else {
                    return false
                }
                newestFirstEvents = snapshot.events
                fileBytes = snapshot.data.count
                return true
            } else {
                guard appendLine(line, to: fileURL) else {
                    return false
                }
                fileBytes += line.count
            }
        }

        insertNewestFirst(event)
        trimMemoryIfNeeded()
        return true
    }

    /// Returns the newest recorded events in deterministic order.
    ///
    /// - Parameter limit: Maximum number of events returned.
    /// - Returns: Events ordered by timestamp and stable identifier, newest first.
    public func recentEvents(limit: Int = .max) async -> [VaultHistoryEvent] {
        loadIfNeeded()
        guard limit < newestFirstEvents.count else {
            return newestFirstEvents
        }
        return Array(newestFirstEvents.prefix(max(0, limit)))
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
        newestFirstEvents = Array(
            loadedEvents
                .sorted(by: VaultHistoryEvent.newestFirst)
                .prefix(retention.maxStoredEvents)
        )
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

    private func compactedSnapshot(
        including event: VaultHistoryEvent
    ) -> (events: [VaultHistoryEvent], data: Data) {
        var candidates = newestFirstEvents
        let insertionIndex = candidates.firstIndex {
            VaultHistoryEvent.newestFirst(event, $0)
        } ?? candidates.endIndex
        candidates.insert(event, at: insertionIndex)
        if candidates.count > retention.maxStoredEvents {
            candidates.removeLast(candidates.count - retention.maxStoredEvents)
        }

        var retainedEvents: [VaultHistoryEvent] = []
        var retainedLines: [Data] = []
        var retainedBytes = 0
        for candidate in candidates {
            guard let line = encodedLine(for: candidate),
                  line.count <= retention.maxFileBytes else {
                continue
            }
            guard retainedBytes + line.count <= retention.maxFileBytes else {
                break
            }
            retainedEvents.append(candidate)
            retainedLines.append(line)
            retainedBytes += line.count
        }

        var data = Data(capacity: retainedBytes)
        // JSONL stays chronological so bounded tail reads always contain the
        // newest retained records, even after an out-of-order append.
        for line in retainedLines.reversed() {
            data.append(line)
        }
        return (retainedEvents, data)
    }

    private func writeCompactedData(_ data: Data, to fileURL: URL) -> Bool {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func insertNewestFirst(_ event: VaultHistoryEvent) {
        let index = newestFirstEvents.firstIndex {
            VaultHistoryEvent.newestFirst(event, $0)
        } ?? newestFirstEvents.endIndex
        newestFirstEvents.insert(event, at: index)
    }

    private func trimMemoryIfNeeded() {
        guard newestFirstEvents.count > retention.maxStoredEvents else { return }
        newestFirstEvents.removeLast(
            newestFirstEvents.count - retention.maxStoredEvents
        )
    }
}
