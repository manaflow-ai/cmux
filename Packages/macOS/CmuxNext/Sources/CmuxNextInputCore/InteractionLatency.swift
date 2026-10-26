/// cmux's Interaction to Next Paint (web.dev/articles/inp): a person's events grouped into
/// interactions, each interaction as long as its longest event, and per session the count, the
/// worst one, and a high percentile that ignores one interaction for each 50.
///
/// Chromium's design: `third_party/blink/renderer/core/timing/responsiveness_metrics.cc` groups
/// keydown/keyup by key code and pointerdown/pointerup by pointer into one interaction whose
/// latency is the longest event; `components/page_load_metrics/browser/
/// responsiveness_metrics_normalization.cc` keeps a fixed list of the worst latencies and reports
/// `ApproximateHighPercentile()`, the entry at `min(count / 50, size - 1)`.
///
/// Pairing:
/// - Key: ``InputEventKind/keyPress`` opens one, the ``InputEventKind/keyRelease`` of the same key
///   code closes it. A key with no release closes at the next key press (an auto-repeat press is
///   its own interaction). A release with no open press of its key is dropped.
/// - Pointer: ``InputEventKind/mousePress`` opens one, ``InputEventKind/mouseRelease`` closes it;
///   a ``InputEventKind/drag`` in between makes it a drag. Drag moves add no latency (Chrome counts
///   pointerdown and pointerup only). A press with no release closes at the next press.
/// - Scrolls, moves, modifier flags and magnify are not interactions (Chrome leaves scroll out of
///   INP). Synthetic input (``InputEntrypoint/automation``) is left out, as INP counts only
///   trusted events.
///
/// A plain value (`_isPOD`): no reference, no array, so recording never allocates. Its owner
/// (``InputLatencyLedger``, folded off the main thread) mutates it; it holds no lock.
///
/// ```swift
/// var interactions = InteractionLatency()
/// interactions.record(slot)            // pairs by the slot's kind and key code
/// let summary = interactions.summary   // count, worst, INP high percentile
/// ```
public struct InteractionLatency: Sendable, Equatable {
    /// What kind of interaction a person made.
    public enum Kind: UInt8, Sendable, Hashable, CaseIterable {
        /// A key press and its release.
        case key
        /// A mouse press and its release with no drag.
        case tap
        /// A mouse press, a drag and the release.
        case drag

        /// The closed-set name the opt-in report and `debug.input` write.
        public var wireName: String {
            switch self {
            case .key: "key"
            case .tap: "tap"
            case .drag: "drag"
            }
        }
    }

    /// One session's closed interactions: numbers and kind/target only.
    public struct Summary: Sendable, Equatable {
        /// Interactions closed in the session.
        public var count: UInt64
        /// The longest interaction, in nanoseconds (0 with none).
        public var worstNanos: UInt64
        /// The INP value: the longest interaction after ignoring one for each 50, in nanoseconds.
        public var highPercentileNanos: UInt64
        /// The kind of the longest interaction, nil with none.
        public var kindOfWorst: Kind?
        /// Where the longest interaction landed, nil with none.
        public var targetOfWorst: InputTarget?

        /// The longest interaction in milliseconds.
        public var worstMs: Double { Double(worstNanos) / 1_000_000 }
        /// The INP value in milliseconds.
        public var highPercentileMs: Double { Double(highPercentileNanos) / 1_000_000 }
    }

    /// The worst latencies kept: enough for the percentile up to 549 interactions (index 10),
    /// Chrome's `kMaxNumOfLatencyEntries` of 10 plus one.
    public static let keptWorst = 11
    /// One interaction ignored for each this many (Chrome's `kHighPercentileUpdateFrequency`).
    public static let interactionsPerIgnored: UInt64 = 50

    private var key = Pending()
    private var pointer = Pending()
    private var worstList = WorstList()
    private var count: UInt64 = 0
    private var worstNanos: UInt64 = 0
    private var kindOfWorst: Kind?
    private var targetOfWorst: InputTarget?

    /// No interaction yet.
    public init() {}

    /// The closed interactions so far (an open one is not in it until it closes).
    public var summary: Summary {
        Summary(
            count: count,
            worstNanos: worstNanos,
            highPercentileNanos: worstList.value(
                at: Int(min(count / Self.interactionsPerIgnored, UInt64(Self.keptWorst - 1)))),
            kindOfWorst: kindOfWorst,
            targetOfWorst: targetOfWorst
        )
    }

    /// Folds one closed input slot, paired by its kind and ``InputLatencySlot/keyCode``. Its
    /// latency is generated to presented, or to the main commit or dispatch end when nothing was
    /// presented (a key that changed nothing on screen).
    public mutating func record(_ slot: InputLatencySlot) {
        let latency = slot.totalNanos
            ?? slot.nanos(from: .generated, to: .mainCommit)
            ?? slot.nanos(from: .generated, to: .dispatchEnd)
            ?? 0
        record(kind: slot.kind, target: slot.target, entrypoint: slot.entrypoint, keyCode: slot.keyCode,
               latencyNanos: latency)
    }

    /// Folds one event of `kind` that took `latencyNanos`; `keyCode` pairs a key press with its
    /// release and is ignored for other kinds.
    public mutating func record(
        kind: InputEventKind,
        target: InputTarget,
        entrypoint: InputEntrypoint,
        keyCode: UInt16,
        latencyNanos: UInt64
    ) {
        guard entrypoint == .person else { return }
        switch kind {
        case .keyPress:
            if key.isOpen { closeKey() }
            key.open(keyCode: keyCode, target: target, latencyNanos: latencyNanos)
        case .keyRelease:
            guard key.isOpen, key.keyCode == keyCode else { return }
            key.add(latencyNanos)
            closeKey()
        case .mousePress:
            if pointer.isOpen { closePointer() }
            pointer.open(keyCode: 0, target: target, latencyNanos: latencyNanos)
        case .drag:
            if pointer.isOpen { pointer.dragged = true }
        case .mouseRelease:
            guard pointer.isOpen else { return }
            pointer.add(latencyNanos)
            closePointer()
        case .flags, .pointerMove, .scrollBegin, .scrollFirstUpdate, .scrollUpdate, .scrollMomentum, .scrollEnd,
             .magnify:
            return
        }
    }

    /// Moves the closed interactions out and returns them; the key and pointer interactions still
    /// open stay, so one that spans a report boundary is counted once, in the report it closes in
    /// (as ``InputLatencyLedger/takeCounts()`` keeps a scroll in progress).
    public mutating func takeCounts() -> InteractionLatency {
        var counts = InteractionLatency()
        counts.worstList = worstList
        counts.count = count
        counts.worstNanos = worstNanos
        counts.kindOfWorst = kindOfWorst
        counts.targetOfWorst = targetOfWorst
        worstList = WorstList()
        count = 0
        worstNanos = 0
        kindOfWorst = nil
        targetOfWorst = nil
        return counts
    }

    /// Adds `other`'s closed interactions; its open ones are not counts and are left out. Each side
    /// keeps its own 11 worst, so the merged list is exactly the 11 worst of both.
    public mutating func addCounts(_ other: InteractionLatency) {
        guard other.count > 0 else { return }
        if count == 0 || other.worstNanos > worstNanos {
            worstNanos = other.worstNanos
            kindOfWorst = other.kindOfWorst
            targetOfWorst = other.targetOfWorst
        }
        count &+= other.count
        worstList.insert(contentsOf: other.worstList)
    }

    private mutating func closeKey() {
        let closed = key
        key = Pending()
        close(latency: closed.latencyNanos, target: closed.target, kind: .key)
    }

    private mutating func closePointer() {
        let closed = pointer
        pointer = Pending()
        close(latency: closed.latencyNanos, target: closed.target, kind: closed.dragged ? .drag : .tap)
    }

    private mutating func close(latency: UInt64, target: InputTarget, kind: Kind) {
        count &+= 1
        if count == 1 || latency > worstNanos {
            worstNanos = latency
            kindOfWorst = kind
            targetOfWorst = target
        }
        worstList.insert(latency)
    }
}

extension InteractionLatency {
    /// The interaction a press opened and its release has not closed.
    struct Pending: Sendable, Equatable {
        var isOpen = false
        var dragged = false
        var keyCode: UInt16 = 0
        var target: InputTarget = .other
        var latencyNanos: UInt64 = 0

        mutating func open(keyCode: UInt16, target: InputTarget, latencyNanos: UInt64) {
            self = Pending(isOpen: true, dragged: false, keyCode: keyCode, target: target, latencyNanos: latencyNanos)
        }

        /// An interaction is as long as its longest event.
        mutating func add(_ latencyNanos: UInt64) {
            self.latencyNanos = max(self.latencyNanos, latencyNanos)
        }
    }

    /// The ``InteractionLatency/keptWorst`` longest latencies, longest first, in a fixed inline
    /// tuple: inserting shifts at most 11 words and never allocates.
    struct WorstList: Sendable, Equatable {
        typealias Storage = (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)

        private var storage: Storage = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        private(set) var size = 0

        static func == (lhs: WorstList, rhs: WorstList) -> Bool {
            guard lhs.size == rhs.size else { return false }
            return (0 ..< lhs.size).allSatisfy { lhs.value(at: $0) == rhs.value(at: $0) }
        }

        /// The `index`-th longest kept latency (0 = longest), clamped to the last kept one;
        /// 0 when nothing is kept.
        func value(at index: Int) -> UInt64 {
            guard size > 0 else { return 0 }
            let index = min(max(0, index), size - 1)
            return withUnsafeBytes(of: storage) { $0.load(fromByteOffset: index * MemoryLayout<UInt64>.stride, as: UInt64.self) }
        }

        /// Keeps `latency` when it is among the longest.
        mutating func insert(_ latency: UInt64) {
            let capacity = InteractionLatency.keptWorst
            let used = size
            if used == capacity, value(at: capacity - 1) >= latency { return }
            size = withUnsafeMutableBytes(of: &storage) { raw in
                let words = raw.bindMemory(to: UInt64.self)
                var position = min(used, capacity - 1)
                while position > 0, words[position - 1] < latency {
                    words[position] = words[position - 1]
                    position -= 1
                }
                words[position] = latency
                return min(used + 1, capacity)
            }
        }

        /// Keeps each of `other`'s latencies that is among the longest.
        mutating func insert(contentsOf other: WorstList) {
            for index in 0 ..< other.size { insert(other.value(at: index)) }
        }
    }
}
