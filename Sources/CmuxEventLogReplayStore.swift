import Foundation
import os

/// Reads the bounded event-log generations used to seed and replay a stream.
// Sendable safety: the file configuration is immutable and the cached snapshot
// is replaced only through `cachedSnapshot`.
final class CmuxEventLogReplayStore: @unchecked Sendable {
    // Sendable safety: snapshots contain immutable JSON values produced by
    // JSONSerialization and are replaced atomically under `cachedSnapshot`.
    struct Snapshot: @unchecked Sendable {
        let events: [[String: Any]]
        let latestSequence: Int64?
    }

    private struct IndexedEvent {
        let event: [String: Any]
        let sequence: Int64
        let ordinal: Int
    }

    private let eventLogURL: URL
    private let maxEventLineBytes: Int
    // Lock justification: subscriptions synchronously copy this tiny cache while
    // the event-log writer refreshes it off the socket worker thread.
    private let cachedSnapshot: OSAllocatedUnfairLock<Snapshot>

    init(eventLogURL: URL, maxEventLineBytes: Int) {
        self.eventLogURL = eventLogURL
        self.maxEventLineBytes = max(1, maxEventLineBytes)
        self.cachedSnapshot = OSAllocatedUnfairLock(
            initialState: Self.readSnapshot(
                eventLogURL: eventLogURL,
                maxEventLineBytes: max(1, maxEventLineBytes)
            )
        )
    }

    func snapshot() -> Snapshot {
        cachedSnapshot.withLockUnchecked { $0 }
    }

    /// Refreshes the cached replay snapshot from disk.
    ///
    /// The event-log writer calls this after its utility-queue append completes;
    /// callers serving a socket subscription should use ``snapshot()`` instead.
    func refreshFromDisk() {
        let snapshot = Self.readSnapshot(
            eventLogURL: eventLogURL,
            maxEventLineBytes: maxEventLineBytes
        )
        cachedSnapshot.withLockUnchecked { $0 = snapshot }
    }

    private static func readSnapshot(eventLogURL: URL, maxEventLineBytes: Int) -> Snapshot {
        var eventsByID: [String: IndexedEvent] = [:]
        var anonymousEvents: [IndexedEvent] = []
        var ordinal = 0

        for url in [eventLogURL.appendingPathExtension("1"), eventLogURL] {
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                defer { ordinal += 1 }
                guard line.count <= maxEventLineBytes,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["type"] as? String == "event",
                      let sequence = CmuxEventBus.int64(object["seq"]),
                      sequence >= 1 else {
                    continue
                }

                let indexed = IndexedEvent(event: object, sequence: sequence, ordinal: ordinal)
                if let id = object["id"] as? String, !id.isEmpty {
                    eventsByID[id] = indexed
                } else {
                    anonymousEvents.append(indexed)
                }
            }
        }

        var indexedEvents = Array(eventsByID.values) + anonymousEvents
        indexedEvents.sort {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.ordinal < $1.ordinal
        }

        return Snapshot(
            events: indexedEvents.map(\.event),
            latestSequence: indexedEvents.last?.sequence
        )
    }
}
