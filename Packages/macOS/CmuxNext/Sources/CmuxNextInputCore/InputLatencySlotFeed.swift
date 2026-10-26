/// The producer of ``InputLatencyFeed``: the input latency tracker calls ``publish(_:)`` with each
/// slot it closes, on the main thread, next to its ring append; the Debug latency HUD reads
/// ``closedSlots(replaying:)`` while it is shown.
///
/// ``publish(_:)`` is always on: one slot copy into a buffer of ``kept`` slots made in `init` and
/// a check for readers, with no allocation, lock or string. Each reader gets its own stream that
/// holds ``kept`` slots (`bufferingNewest`); a slot that does not fit is counted in
/// ``droppedCount``, so a slow reader never holds the main thread or grows memory. A reader ends
/// when its iterating task is cancelled, and the feed forgets it.
///
/// ```swift
/// let feed = InputLatencySlotFeed()
/// feed.publish(slot)  // the tracker, per closed slot
/// for await slot in feed.closedSlots(replaying: 16) { show(slot) }
/// ```
@MainActor
public final class InputLatencySlotFeed: InputLatencyFeed {
    /// Closed slots kept for a new reader and buffered per reader unless told otherwise.
    public static let defaultKept = 16

    /// Closed slots kept for a new reader, and each reader's buffer.
    public let kept: Int
    /// Slots published since the feed was made.
    public private(set) var publishedCount: UInt64 = 0
    /// Slots a reader's stream dropped because the reader fell behind.
    public private(set) var droppedCount: UInt64 = 0

    /// The newest ``kept`` slots; slot `n` is at `n % kept`.
    private var recent: ContiguousArray<InputLatencySlot>
    private var readers: [UInt64: AsyncStream<InputLatencySlot>.Continuation] = [:]
    private var nextReader: UInt64 = 0

    /// A feed that keeps the newest `kept` slots (at least 1).
    public init(keeping kept: Int = InputLatencySlotFeed.defaultKept) {
        self.kept = max(1, kept)
        recent = ContiguousArray(repeating: InputLatencySlot(kind: .keyPress, target: .other, entrypoint: .person), count: self.kept)
    }

    /// Hands one closed slot to every reader without waiting, and keeps it for the next reader.
    public func publish(_ slot: InputLatencySlot) {
        recent[Int(publishedCount % UInt64(kept))] = slot
        publishedCount &+= 1
        guard !readers.isEmpty else { return }
        var ended: [UInt64] = []
        for (id, reader) in readers {
            let result = reader.yield(slot)
            if case .dropped = result {
                droppedCount &+= 1
            } else if case .terminated = result {
                ended.append(id)
            }
        }
        for id in ended { readers[id] = nil }
    }

    public func closedSlots(replaying count: Int) -> AsyncStream<InputLatencySlot> {
        let id = nextReader
        nextReader &+= 1
        let (stream, continuation) = AsyncStream<InputLatencySlot>.makeStream(bufferingPolicy: .bufferingNewest(kept))
        for slot in recentSlots(count) { continuation.yield(slot) }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.removeReader(id) }
        }
        readers[id] = continuation
        return stream
    }

    /// The newest `count` slots published (at most ``kept``), oldest first.
    public func recentSlots(_ count: Int) -> [InputLatencySlot] {
        let wanted = UInt64(min(max(count, 0), kept))
        let first = publishedCount - min(wanted, publishedCount)
        return (first..<publishedCount).map { recent[Int($0 % UInt64(kept))] }
    }

    /// Readers still registered (tests: an ended stream is forgotten).
    public var readerCount: Int { readers.count }

    private func removeReader(_ id: UInt64) {
        readers[id] = nil
    }
}
