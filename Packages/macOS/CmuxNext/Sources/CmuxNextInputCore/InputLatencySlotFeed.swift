/// The producer of ``InputLatencyFeed``: the input latency tracker calls ``publish(_:)`` with each
/// slot it closes, on the main thread, next to its ring append; the Debug latency HUD is a reader
/// while it is shown.
///
/// ``publish(_:)`` is always on: one slot copy into a buffer of ``kept`` slots made in `init` and
/// a check for readers, with no allocation, lock or string. Each reader is called in the
/// publishing turn, so no slot waits in a buffer and none is dropped.
///
/// ```swift
/// let feed = InputLatencySlotFeed()
/// let reader = feed.addReader(replaying: 16) { slot in show(slot) }
/// feed.publish(slot)  // the tracker, per closed slot
/// feed.removeReader(reader)
/// ```
@MainActor
public final class InputLatencySlotFeed: InputLatencyFeed {
    /// Closed slots kept for a new reader unless told otherwise.
    public static let defaultKept = 16

    /// Closed slots kept for a new reader.
    public let kept: Int
    /// Slots published since the feed was made.
    public private(set) var publishedCount: UInt64 = 0

    /// The newest ``kept`` slots; slot `n` is at `n % kept`.
    private var recent: ContiguousArray<InputLatencySlot>
    private var readers: [(reader: InputLatencyReader, read: @MainActor (InputLatencySlot) -> Void)] = []
    private var nextReader: UInt64 = 0

    /// A feed that keeps the newest `kept` slots (at least 1).
    public init(keeping kept: Int = InputLatencySlotFeed.defaultKept) {
        self.kept = max(1, kept)
        recent = ContiguousArray(repeating: InputLatencySlot(kind: .keyPress, target: .other, entrypoint: .person), count: self.kept)
    }

    /// Hands one closed slot to every reader in this turn, and keeps it for the next reader.
    public func publish(_ slot: InputLatencySlot) {
        recent[Int(publishedCount % UInt64(kept))] = slot
        publishedCount &+= 1
        // A copy: a reader may remove itself or add another while it reads.
        for entry in readers { entry.read(slot) }
    }

    public func addReader(replaying count: Int, _ read: @escaping @MainActor (InputLatencySlot) -> Void) -> InputLatencyReader {
        let reader = InputLatencyReader(id: nextReader)
        nextReader &+= 1
        readers.append((reader, read))
        for slot in recentSlots(count) { read(slot) }
        return reader
    }

    public func removeReader(_ reader: InputLatencyReader) {
        readers.removeAll { $0.reader == reader }
    }

    /// The newest `count` slots published (at most ``kept``), oldest first.
    public func recentSlots(_ count: Int) -> [InputLatencySlot] {
        let wanted = UInt64(min(max(count, 0), kept))
        let first = publishedCount - min(wanted, publishedCount)
        return (first..<publishedCount).map { recent[Int($0 % UInt64(kept))] }
    }

    /// Readers still registered (tests: a removed reader is forgotten).
    public var readerCount: Int { readers.count }
}
