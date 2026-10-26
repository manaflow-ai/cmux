/// The continuous pointer input that ``PointerCoalescingQueue`` merges between frames (Chromium's
/// continuous events: mouse move and wheel, `third_party/blink/renderer/platform/widget/input/
/// main_thread_event_queue.cc` `IsContinuousEvent`). Buttons, keys and gestures are discrete: they are
/// never merged, and they flush what is pending first.
public enum PointerCoalescedKind: UInt8, Hashable, Sendable {
    /// The pointer moved with no button down: the latest move wins.
    case move
    /// The pointer moved with a button down: the latest point wins and the last
    /// ``PointerCoalescedInput/sampleCapacity`` points are kept for velocity.
    case drag
    /// A scroll wheel or trackpad scroll: deltas are summed within one phase.
    case scroll

    /// The kind of a continuous event type; nil for a discrete one.
    public init?(_ type: InputEventType) {
        switch type.eventClass {
        case .pointerMove: self = .move
        case .drag: self = .drag
        case .scroll: self = .scroll
        case .key, .flags, .button, .gesture, .tracking: return nil
        }
    }
}

/// One pointer position and its OS event time, kept for a drag's velocity (Chromium keeps the
/// originals of a coalesced event for `getCoalescedEvents`, `web_coalesced_input_event.h`).
public struct PointerSample: Hashable, Sendable {
    /// The pointer in the event's window.
    public var location: InputPoint
    /// Seconds since boot (the clock of `NSEvent.timestamp`).
    public var timestamp: Double

    public init(location: InputPoint, timestamp: Double) {
        self.location = location
        self.timestamp = timestamp
    }
}

/// One delivery of continuous pointer input: one event, or several of the same kind merged, as
/// Chromium's `WebCoalescedInputEvent` (`third_party/blink/common/input/web_coalesced_input_event.cc`).
///
/// - Moves: ``latest`` is the newest move (latest wins).
/// - Drags: ``latest`` is the newest drag, and ``samples`` the newest ``sampleCapacity`` points, oldest first,
///   so a velocity estimate sees every point a frame carried.
/// - Scrolls: ``scrollDelta`` is the sum of the merged deltas; only one scroll phase is merged, so a
///   phase change (began, changed, ended, momentum) starts a new delivery.
///
/// A merged delivery keeps the oldest event's time (``oldestTimestamp``) and how many events it covers
/// (``coalescedCount``), as `WebCoalescedInputEvent` keeps the oldest event's latency and a coalesced
/// count: the latency tracker measures the worst wait, not the best.
public struct PointerCoalescedInput: Hashable, Sendable {
    /// The drag points a delivery keeps: one 60 Hz frame of 1000 Hz input (p04-input.md (C)).
    public static let sampleCapacity = 16

    public let kind: PointerCoalescedKind
    /// The newest event merged in.
    public private(set) var latest: InputEventRecord
    /// The OS event time of the oldest event merged in (seconds since boot).
    public private(set) var oldestTimestamp: Double
    /// How many OS events this delivery covers (1 for one event).
    public private(set) var coalescedCount: Int
    /// The sum of the merged scroll deltas; zero for moves and drags.
    public private(set) var scrollDelta: InputPoint
    /// A drag's newest points, oldest first (at most ``sampleCapacity``); empty for moves and scrolls.
    public private(set) var samples: [PointerSample]

    /// A delivery of `record` alone; nil when the record is not continuous pointer input.
    public init?(_ record: InputEventRecord) {
        self.init(record, sampleBuffer: [])
    }

    /// A delivery of `record` alone whose drag samples reuse `sampleBuffer`'s storage (an emptied buffer
    /// from ``PointerCoalescingQueue``'s pool), so a drag frame allocates nothing.
    init?(_ record: InputEventRecord, sampleBuffer: [PointerSample]) {
        guard let kind = PointerCoalescedKind(record.type) else { return nil }
        self.kind = kind
        latest = record
        oldestTimestamp = record.timestamp
        coalescedCount = 1
        scrollDelta = kind == .scroll ? record.scrollDelta : .zero
        samples = sampleBuffer
        guard kind == .drag else { return }
        if samples.capacity < Self.sampleCapacity { samples.reserveCapacity(Self.sampleCapacity) }
        samples.append(PointerSample(location: record.location, timestamp: record.timestamp))
    }

    /// Moves the samples' storage out, leaving none: the queue's pool takes it back after the delivery.
    mutating func takeSamples() -> [PointerSample] {
        var taken: [PointerSample] = []
        swap(&taken, &samples)
        return taken
    }

    /// Whether `record` merges into this delivery (Chromium's `CanCoalesceWith`): the same kind, window,
    /// modifiers and button; for scrolls also the same phase and delta units (precise or lines).
    public func canMerge(_ record: InputEventRecord) -> Bool {
        guard PointerCoalescedKind(record.type) == kind,
              record.type == latest.type,
              record.windowNumber == latest.windowNumber,
              record.modifierFlags == latest.modifierFlags
        else { return false }
        switch kind {
        case .move: return true
        case .drag: return record.buttonNumber == latest.buttonNumber
        case .scroll:
            return record.scrollPhase == latest.scrollPhase
                && record.hasPreciseScrollingDeltas == latest.hasPreciseScrollingDeltas
        }
    }

    /// Merges `record` in (Chromium's `CoalesceWith`); false, and no change, when it does not merge.
    @discardableResult
    public mutating func merge(_ record: InputEventRecord) -> Bool {
        guard canMerge(record) else { return false }
        latest = record
        coalescedCount += 1
        switch kind {
        case .move:
            break
        case .drag:
            if samples.count == Self.sampleCapacity { samples.removeFirst() }
            samples.append(PointerSample(location: record.location, timestamp: record.timestamp))
        case .scroll:
            scrollDelta = InputPoint(x: scrollDelta.x + record.scrollDelta.x, y: scrollDelta.y + record.scrollDelta.y)
        }
        return true
    }
}
