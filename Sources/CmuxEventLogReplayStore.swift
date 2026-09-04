import Foundation
import os

/// Persists the next sequence independently of the best-effort JSONL log.
/// A floor value survives a restart even when an enqueued event never reaches
/// the writer, so sequence numbers cannot be silently reused.
final class CmuxEventSequenceFloor: @unchecked Sendable {
    struct State {
        let nextSequence: Int64?
        let isPresent: Bool
        let isUnreadable: Bool
    }

    let url: URL
    // Calls are serialized by CmuxEventBus's floor-write lane. Keeping this
    // bit on the floor object avoids another directory syscall for each
    // reserved sequence block while still allowing recovery after a failure.
    private var directoryCreated = false

    init(eventLogURL: URL) {
        self.url = eventLogURL.appendingPathExtension("seq")
    }

    func read() -> State {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return State(nextSequence: nil, isPresent: false, isUnreadable: false)
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let nextSequence = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              nextSequence >= 1 else {
            return State(nextSequence: nil, isPresent: true, isUnreadable: true)
        }
        return State(nextSequence: nextSequence, isPresent: true, isUnreadable: false)
    }

    func restoration(durableLatestSequence: Int64?) -> (nextSequence: Int64, hasGap: Bool) {
        let durableNextSequence = Self.nextSequence(after: durableLatestSequence)
        let state = read()
        let restoredNextSequence = max(durableNextSequence, state.nextSequence ?? 1)
        let hasGap: Bool
        if state.isUnreadable {
            hasGap = true
        } else if durableLatestSequence != nil,
                  let persistedNextSequence = state.nextSequence {
            hasGap = persistedNextSequence > durableNextSequence
        } else {
            // The durable high-water mark is loaded asynchronously. Defer
            // comparison with a present/missing floor until the bus seeds from
            // that completed snapshot.
            hasGap = false
        }
        return (restoredNextSequence, hasGap)
    }

    /// Replaces the floor atomically, retrying directory creation only after a write failure.
    func write(nextSequence: Int64) -> Bool {
        guard nextSequence >= 1 else { return false }
        // Reservation callers can be delayed after choosing a range. Never let
        // a stale writer move the on-disk floor backwards.
        let persistedNextSequence = read().nextSequence ?? 1
        let valueToWrite = max(nextSequence, persistedNextSequence)
        if !directoryCreated {
            guard createParentDirectory() else { return false }
        }
        do {
            try Data("\(valueToWrite)\n".utf8).write(to: url, options: [.atomic])
            return true
        } catch {
            directoryCreated = false
            guard createParentDirectory() else { return false }
            do {
                try Data("\(valueToWrite)\n".utf8).write(to: url, options: [.atomic])
                return true
            } catch {
                directoryCreated = false
                return false
            }
        }
    }

    private func createParentDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            directoryCreated = true
            return true
        } catch {
            return false
        }
    }

    private static func nextSequence(after latestSequence: Int64?) -> Int64 {
        guard let latestSequence else { return 1 }
        return latestSequence == Int64.max ? Int64.max : latestSequence + 1
    }
}

/// Maintains an ordered, bounded replay view of the event-log generations.
// Sendable safety: the file configuration is immutable and the cached state is
// replaced or mutated only while `cachedState` is held.
final class CmuxEventLogReplayStore: @unchecked Sendable {
    // Sendable safety: JSON values are immutable after decoding and are never
    // mutated through the replay store.
    struct Snapshot: @unchecked Sendable {
        let events: [[String: Any]]
        let eventsByID: [String: [String: Any]]
        let sequences: [Int64]
        let sequenceStartIndices: [Int]
        let latestSequence: Int64?
        let hasUnavailableRange: Bool

        /// Returns the first event whose sequence is greater than `sequence`.
        /// `sequenceStartIndices` makes this a binary search over sequence
        /// groups instead of a scan through the durable event history.
        func firstEventIndex(after sequence: Int64) -> Int {
            var lower = 0
            var upper = sequences.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if sequences[middle] <= sequence {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower < sequenceStartIndices.count
                ? sequenceStartIndices[lower]
                : events.count
        }
    }

    private struct IndexedEvent {
        let event: [String: Any]
        let sequence: Int64
        let id: String?
        let ordinal: Int
    }

    private struct GenerationRead {
        let events: [IndexedEvent]
        let unavailable: Bool
    }

    // Sendable safety: all JSON storage is protected by `cachedState`; the
    // unchecked conformance is needed because Foundation's `Any` is opaque.
    private struct Cache: @unchecked Sendable {
        var events: [[String: Any]]
        var eventsByID: [String: [String: Any]]
        var sequences: [Int64]
        var sequenceStartIndices: [Int]
        var latestSequence: Int64?
        var hasUnavailableRange: Bool

        func snapshot() -> Snapshot {
            Snapshot(
                events: events,
                eventsByID: eventsByID,
                sequences: sequences,
                sequenceStartIndices: sequenceStartIndices,
                latestSequence: latestSequence,
                hasUnavailableRange: hasUnavailableRange
            )
        }

        mutating func append(_ indexedEvents: [IndexedEvent]) -> Bool {
            guard !indexedEvents.isEmpty else { return true }

            var previousSequence = latestSequence ?? 0
            var batchIDs = Set<String>()
            for indexed in indexedEvents {
                guard indexed.sequence > previousSequence else { return false }
                if let id = indexed.id {
                    guard eventsByID[id] == nil, batchIDs.insert(id).inserted else { return false }
                }
                previousSequence = indexed.sequence
            }

            for indexed in indexedEvents {
                if sequences.last != indexed.sequence {
                    sequences.append(indexed.sequence)
                    sequenceStartIndices.append(events.count)
                }
                events.append(indexed.event)
                if let id = indexed.id {
                    eventsByID[id] = indexed.event
                }
            }
            latestSequence = previousSequence
            return true
        }
    }

    private let eventLogURL: URL
    private let maxEventLineBytes: Int
    private let maxEventLogBytes: UInt64
    // Initial parsing runs on a utility lane so constructing CmuxEventBus does
    // not make a main-actor publisher synchronously read both 16 MiB files.
    private static let initialLoadQueue = DispatchQueue(
        label: "com.cmux.event-log-replay-load",
        qos: .utility
    )
    // This is a one-shot readiness signal, not mutable-state synchronization;
    // callers wait only until the utility load publishes the first snapshot.
    private let initialLoadGroup: DispatchGroup
    // Lock justification: subscriptions copy the ordered cache while the
    // event-log utility queue applies persisted batches in the background.
    private let cachedState: OSAllocatedUnfairLock<Cache>

    /// Creates a bounded replay cache seeded from both event-log generations.
    init(
        eventLogURL: URL,
        maxEventLineBytes: Int,
        maxEventLogBytes: UInt64 = CmuxEventBus.defaultMaxEventLogBytes
    ) {
        let normalizedLineBytes = max(1, maxEventLineBytes)
        let normalizedLogBytes = max(1, maxEventLogBytes)
        self.eventLogURL = eventLogURL
        self.maxEventLineBytes = normalizedLineBytes
        self.maxEventLogBytes = normalizedLogBytes
        self.cachedState = OSAllocatedUnfairLock(initialState: Cache(
            events: [],
            eventsByID: [:],
            sequences: [],
            sequenceStartIndices: [],
            latestSequence: nil,
            hasUnavailableRange: false
        ))
        let initialLoadGroup = DispatchGroup()
        initialLoadGroup.enter()
        self.initialLoadGroup = initialLoadGroup
        startInitialLoad()
    }

    /// Returns the latest ordered cache after the initial utility load completes.
    func snapshot() -> Snapshot {
        waitForInitialLoad()
        return cachedState.withLockUnchecked { $0.snapshot() }
    }

    /// Returns the durable high-water mark after the initial utility load.
    func latestSequenceForStartup() -> Int64? {
        waitForInitialLoad()
        return cachedState.withLockUnchecked { $0.latestSequence }
    }

    /// Applies a successfully persisted writer batch without rescanning either
    /// generation. Rotation, write failure, or malformed data falls back to a
    /// bounded full rebuild so the cache cannot drift from disk.
    func apply(_ batch: CmuxEventLogPersistedBatch) {
        waitForInitialLoad()
        guard !batch.didRotate, !batch.didFail else {
            refreshFromDisk()
            return
        }
        guard !batch.lines.isEmpty,
              let indexedEvents = Self.parsePersistedEvents(
                  batch.lines,
                  maxEventLineBytes: maxEventLineBytes
              ) else {
            refreshFromDisk()
            return
        }

        var requiresRefresh = false
        cachedState.withLockUnchecked { state in
            if !state.append(indexedEvents) {
                requiresRefresh = true
            }
        }
        if requiresRefresh {
            refreshFromDisk()
        }
    }

    /// Rebuilds the cache after startup, rotation, an append failure, or a
    /// detected ordering/identity inconsistency.
    func refreshFromDisk() {
        waitForInitialLoad()
        let state = Self.initialLoadQueue.sync {
            Self.readCache(
                eventLogURL: eventLogURL,
                maxEventLineBytes: maxEventLineBytes,
                maxEventLogBytes: maxEventLogBytes
            )
        }
        cachedState.withLockUnchecked { $0 = state }
    }

    private func startInitialLoad() {
        Self.initialLoadQueue.async { [self] in
            defer { initialLoadGroup.leave() }
            let state = Self.readCache(
                eventLogURL: eventLogURL,
                maxEventLineBytes: maxEventLineBytes,
                maxEventLogBytes: maxEventLogBytes
            )
            cachedState.withLockUnchecked { $0 = state }
        }
    }

    private func waitForInitialLoad() {
        initialLoadGroup.wait()
    }

    /// Reads and indexes both generations during initialization or recovery.
    private static func readCache(
        eventLogURL: URL,
        maxEventLineBytes: Int,
        maxEventLogBytes: UInt64
    ) -> Cache {
        var allEvents: [IndexedEvent] = []
        var hasUnavailableRange = false
        var ordinal = 0

        for url in [eventLogURL.appendingPathExtension("1"), eventLogURL] {
            let generation = readGeneration(
                at: url,
                maxEventLineBytes: maxEventLineBytes,
                maxEventLogBytes: maxEventLogBytes,
                ordinal: &ordinal
            )
            allEvents.append(contentsOf: generation.events)
            hasUnavailableRange = hasUnavailableRange || generation.unavailable
        }

        var eventsByID: [String: IndexedEvent] = [:]
        var anonymousEvents: [IndexedEvent] = []
        for indexed in allEvents {
            if let id = indexed.id {
                eventsByID[id] = indexed
            } else {
                anonymousEvents.append(indexed)
            }
        }

        var ordered = Array(eventsByID.values) + anonymousEvents
        ordered.sort {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.ordinal < $1.ordinal
        }
        return makeCache(from: ordered, hasUnavailableRange: hasUnavailableRange)
    }

    /// Materializes the ordered arrays and indexes used by subscriptions.
    private static func makeCache(
        from ordered: [IndexedEvent],
        hasUnavailableRange: Bool
    ) -> Cache {
        var events: [[String: Any]] = []
        var eventsByID: [String: [String: Any]] = [:]
        var sequences: [Int64] = []
        var sequenceStartIndices: [Int] = []
        events.reserveCapacity(ordered.count)

        for indexed in ordered {
            if sequences.last != indexed.sequence {
                sequences.append(indexed.sequence)
                sequenceStartIndices.append(events.count)
            }
            events.append(indexed.event)
            if let id = indexed.id {
                eventsByID[id] = indexed.event
            }
        }

        return Cache(
            events: events,
            eventsByID: eventsByID,
            sequences: sequences,
            sequenceStartIndices: sequenceStartIndices,
            latestSequence: ordered.last?.sequence,
            hasUnavailableRange: hasUnavailableRange
        )
    }

    /// Reads one bounded generation and records any skipped range.
    private static func readGeneration(
        at url: URL,
        maxEventLineBytes: Int,
        maxEventLogBytes: UInt64,
        ordinal: inout Int
    ) -> GenerationRead {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return GenerationRead(events: [], unavailable: false)
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return GenerationRead(events: [], unavailable: true)
        }

        let loaded = readData(
            at: url,
            size: size.uint64Value,
            maxEventLogBytes: maxEventLogBytes
        )
        guard let data = loaded.data else {
            return GenerationRead(events: [], unavailable: true)
        }

        var events: [IndexedEvent] = []
        var skippedRecord = false
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            defer { ordinal += 1 }
            guard line.count <= maxEventLineBytes,
                  let indexed = parseEvent(Data(line), ordinal: ordinal) else {
                skippedRecord = true
                continue
            }
            events.append(indexed)
        }
        return GenerationRead(
            events: events,
            unavailable: loaded.truncated || skippedRecord
        )
    }

    /// Loads a generation in full or returns only its bounded suffix.
    private static func readData(
        at url: URL,
        size: UInt64,
        maxEventLogBytes: UInt64
    ) -> (data: Data?, truncated: Bool) {
        guard size > maxEventLogBytes else {
            return (try? Data(contentsOf: url, options: [.mappedIfSafe]), false)
        }
        guard maxEventLogBytes <= UInt64(Int.max),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return (nil, true)
        }
        defer { try? handle.close() }

        do {
            let offset = size - maxEventLogBytes
            var startsAtLineBoundary = offset == 0
            if offset > 0 {
                try handle.seek(toOffset: offset - 1)
                let previousByte = try handle.read(upToCount: 1)?.first
                startsAtLineBoundary = previousByte == 0x0A
            }
            try handle.seek(toOffset: offset)
            let suffix = try handle.read(upToCount: Int(maxEventLogBytes)) ?? Data()
            guard startsAtLineBoundary else {
                guard let newline = suffix.firstIndex(of: 0x0A) else {
                    return (Data(), true)
                }
                return (Data(suffix[suffix.index(after: newline)...]), true)
            }
            return (suffix, true)
        } catch {
            return (nil, true)
        }
    }

    /// Decodes the writer's successfully appended lines for incremental update.
    private static func parsePersistedEvents(
        _ lines: [String],
        maxEventLineBytes: Int
    ) -> [IndexedEvent]? {
        var indexedEvents: [IndexedEvent] = []
        indexedEvents.reserveCapacity(lines.count)
        for (ordinal, line) in lines.enumerated() {
            guard line.utf8.count <= maxEventLineBytes,
                  let data = line.data(using: .utf8),
                  let indexed = parseEvent(data, ordinal: ordinal) else {
                return nil
            }
            indexedEvents.append(indexed)
        }
        return indexedEvents
    }

    /// Decodes one valid event line into the cache's indexed representation.
    private static func parseEvent(_ data: Data, ordinal: Int) -> IndexedEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event",
              let sequence = CmuxEventBus.int64(object["seq"]),
              sequence >= 1 else {
            return nil
        }
        let id = (object["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return IndexedEvent(event: object, sequence: sequence, id: id, ordinal: ordinal)
    }
}
