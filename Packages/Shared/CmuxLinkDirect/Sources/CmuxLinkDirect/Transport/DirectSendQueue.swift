import CmuxLink
import Foundation

/// A bounded, priority-aware queue for frames waiting to enter the direct
/// TCP socket. Frames remain whole queue items so the record reassembler can
/// never observe segments from two frames interleaved. The queue bounds only
/// unsent bulk bytes; the active frame is already accounted for by
/// `DirectWriter`'s per-frame back-pressure.
struct DirectSendQueue: Sendable {
    struct Entry: Sendable {
        let id: UInt64
        let frame: TransportFrame
        let queuedAt: ContinuousClock.Instant
    }

    private(set) var entries: [Entry] = []
    private(set) var queuedBulkBytes = 0
    let maxQueuedBulkBytes: Int

    init(maxQueuedBulkBytes: Int) {
        self.maxQueuedBulkBytes = max(0, maxQueuedBulkBytes)
    }

    var isEmpty: Bool { entries.isEmpty }

    func canEnqueueBulk(bytes: Int) -> Bool {
        bytes >= 0 && bytes <= maxQueuedBulkBytes - queuedBulkBytes
    }

    func canEnqueue(_ frame: TransportFrame) -> Bool {
        guard frame.lane.priority == .bulk else { return true }
        return canEnqueueBulk(bytes: frame.bytes.count)
    }

    /// Inserts by lane priority, retaining FIFO order for equal priorities.
    /// The caller must check `canEnqueue` for bulk before calling this method.
    mutating func enqueue(_ entry: Entry) {
        if entry.frame.lane.priority == .bulk {
            queuedBulkBytes += entry.frame.bytes.count
        }
        let index = entries.firstIndex { existing in
            existing.frame.lane.priority > entry.frame.lane.priority
        } ?? entries.endIndex
        entries.insert(entry, at: index)
    }

    mutating func dequeue() -> Entry? {
        guard !entries.isEmpty else { return nil }
        let entry = entries.removeFirst()
        if entry.frame.lane.priority == .bulk {
            queuedBulkBytes -= entry.frame.bytes.count
        }
        return entry
    }

    @discardableResult
    mutating func remove(id: UInt64) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let entry = entries.remove(at: index)
        if entry.frame.lane.priority == .bulk {
            queuedBulkBytes -= entry.frame.bytes.count
        }
        return true
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        queuedBulkBytes = 0
    }
}
