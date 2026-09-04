public import Foundation

/// Actor-isolated, retention-bounded JSONL persistence for recorded History events.
public actor VaultHistoryEventStore: VaultHistoryEventStoring {
    private let fileURL: URL?
    private let retention: VaultHistoryRetentionPolicy
    private let fileManager: FileManager
    private var didLoad = false
    /// Append order (oldest to newest), matching the on-disk JSONL layout.
    private var events: [VaultHistoryEvent] = []
    /// Read order, updated incrementally so refreshes never re-sort the store.
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

    /// Persists one event and adds it to the in-memory snapshot only after acceptance.
    ///
    /// - Parameter event: Immutable event to append.
    /// - Returns: `true` when the event was accepted by memory-only storage or persisted.
    public func append(_ event: VaultHistoryEvent) async -> Bool {
        loadIfNeeded()
        guard let line = encodedLine(for: event), line.count <= retention.maxFileBytes else {
            return false
        }
        if let fileURL {
            if fileBytes + line.count > retention.maxFileBytes {
                let snapshot = compactedSnapshot(including: event)
                let orderedSnapshot = newestFirstSnapshot(
                    including: event,
                    retaining: snapshot.events
                )
                guard writeCompactedData(snapshot.data, to: fileURL) else {
                    return false
                }
                events = snapshot.events
                newestFirstEvents = orderedSnapshot
                fileBytes = snapshot.data.count
                return true
            } else {
                guard appendLine(line, to: fileURL) else {
                    return false
                }
                fileBytes += line.count
            }
        }

        events.append(event)
        insertNewestFirst(event)
        for removedEvent in trimMemoryIfNeeded() {
            if let index = newestFirstEvents.firstIndex(of: removedEvent) {
                newestFirstEvents.remove(at: index)
            }
        }
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
        if loadedEvents.count > retention.maxStoredEvents {
            loadedEvents.removeFirst(loadedEvents.count - retention.maxStoredEvents)
        }
        events = loadedEvents
        newestFirstEvents = loadedEvents.sorted(by: VaultHistoryEvent.newestFirst)
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
        var candidates = events
        candidates.append(event)
        if candidates.count > retention.maxStoredEvents {
            candidates.removeFirst(candidates.count - retention.maxStoredEvents)
        }

        var retainedNewestFirst: [VaultHistoryEvent] = []
        var retainedLinesNewestFirst: [Data] = []
        var retainedBytes = 0
        for candidate in candidates.reversed() {
            guard let line = encodedLine(for: candidate),
                  line.count <= retention.maxFileBytes else {
                continue
            }
            guard retainedBytes + line.count <= retention.maxFileBytes else {
                break
            }
            retainedNewestFirst.append(candidate)
            retainedLinesNewestFirst.append(line)
            retainedBytes += line.count
        }

        var data = Data(capacity: retainedBytes)
        for line in retainedLinesNewestFirst.reversed() {
            data.append(line)
        }
        return (Array(retainedNewestFirst.reversed()), data)
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

    private func newestFirstSnapshot(
        including event: VaultHistoryEvent,
        retaining retainedEvents: [VaultHistoryEvent]
    ) -> [VaultHistoryEvent] {
        var ordered = newestFirstEvents
        let insertionIndex = ordered.firstIndex {
            VaultHistoryEvent.newestFirst(event, $0)
        } ?? ordered.endIndex
        ordered.insert(event, at: insertionIndex)

        var remaining = Dictionary(
            retainedEvents.map { ($0, 1) },
            uniquingKeysWith: +
        )
        return ordered.filter { candidate in
            guard let count = remaining[candidate], count > 0 else {
                return false
            }
            remaining[candidate] = count - 1
            return true
        }
    }

    private func trimMemoryIfNeeded() -> [VaultHistoryEvent] {
        guard events.count > retention.maxStoredEvents else { return [] }
        let removalCount = events.count - retention.maxStoredEvents
        let removedEvents = Array(events.prefix(removalCount))
        events.removeFirst(removalCount)
        return removedEvents
    }
}
