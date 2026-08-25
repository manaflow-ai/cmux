import Foundation

/// Reads the bounded event-log generations used to seed and replay a stream.
final class CmuxEventLogReplayStore {
    struct Snapshot {
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

    init(eventLogURL: URL, maxEventLineBytes: Int) {
        self.eventLogURL = eventLogURL
        self.maxEventLineBytes = max(1, maxEventLineBytes)
    }

    func snapshot() -> Snapshot {
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
