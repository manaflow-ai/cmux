internal import Atomics
internal import CmuxNextCompat

/// Names one open slot of an ``InputLatencySlotTable``: the entry index and that entry's
/// generation, so a late mark for an input that was already closed (or whose entry now holds
/// a newer input) is refused instead of written into the wrong input. 0 is never a token, so a
/// cross-process flow id of 0 means "no slot".
public struct InputLatencyToken: Sendable, Hashable {
    /// Generation (24 bits) above the entry index (8 bits).
    public let rawValue: UInt32

    /// The token `rawValue` names (a value read back from a flow id).
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    init(index: Int, generation: UInt64) {
        rawValue = UInt32(truncatingIfNeeded: generation << 8) | UInt32(truncatingIfNeeded: index)
    }

    var index: Int { Int(rawValue & 0xFF) }
    var generation: UInt64 { UInt64(rawValue >> 8) }
}

/// The open input latency slots: a fixed table (128 entries by default) that any thread writes
/// stages into without a lock, so a key's stages can be stamped on the main thread, a writer
/// thread and a reader thread alike (Chromium carries one `EventMetrics` per event through the
/// same stages, cc/metrics/event_metrics.h; here the record stays put and the stages come to it).
///
/// - ``begin(kind:target:entrypoint:generated:keyCode:)`` claims a free entry (one compare-exchange; a
///   rotating cursor makes the first probe hit in the common case) and returns its token. A full
///   table refuses the input and counts it in ``droppedCount``.
/// - ``mark(_:_:at:)`` writes one stage, once: an acquiring load of the entry's state (open, in
///   the token's generation), then a compare-exchange from "empty in this generation" to the
///   time, from any thread. A second mark of the same stage, or a mark with a token whose
///   entry was closed or reused, changes nothing and returns false.
/// - ``close(_:)`` takes the entry back and returns the finished ``InputLatencySlot``; the closing
///   thread appends it to its ``InputLatencyRing`` (single writer).
///
/// Every word of an entry carries the entry's generation, so a write can only land in the input
/// its token names. Stage times are stored as nanoseconds after ``InputStage/generated`` (40 bits,
/// about 18 minutes; longer clamps), which leaves room for the generation in the same word.
///
/// No allocation, lock, string or system call after `init`; callers pass the clock readings.
/// The words are one contiguous buffer of atomics made in `init` (as CmuxNextCompat's
/// `BlockingViolationTable` keeps its counts), each entry on its own 128-byte cache lines, so a
/// close reads two lines and inputs stamped on different threads never share one. Every access
/// to the buffer is an atomic operation, which is why the table is `Sendable`.
public final class InputLatencySlotTable: Sendable {
    /// The entries a table holds unless told otherwise.
    public static let defaultCapacity = 128

    /// Open entries the table can hold (at most 256).
    public let capacity: Int

    /// Read once: a synthesized `allCases` builds a new array on each read.
    private static let stageCount = InputStage.allCases.count
    /// Words per entry: the state, meta and base words, one per stage and the key code word,
    /// rounded up to whole cache lines.
    private static let stride = (4 + stageCount + wordsPerLine - 1) / wordsPerLine * wordsPerLine
    /// Apple silicon's cache line (128 bytes) in words.
    private static let lineBytes = 128
    private static let wordsPerLine = lineBytes / MemoryLayout<UInt64>.stride
    private static let stateWord = 0
    private static let metaWord = 1
    private static let baseWord = 2
    private static let firstStageWord = 3
    /// The key code, written once by ``begin(kind:target:entrypoint:generated:keyCode:)`` before the entry opens.
    private static let keyCodeWord = firstStageWord + stageCount

    private static let generationMask: UInt64 = 0xFF_FFFF
    private static let deltaBits: UInt64 = 40
    private static let deltaMask: UInt64 = (1 << 40) - 1

    private enum Phase: UInt64 {
        case free = 0
        case initializing = 1
        case open = 2
        case closing = 3
    }

    /// ``capacity`` entries of ``stride`` words each, made once in `init`, line-aligned.
    nonisolated(unsafe) private let words: UnsafeMutablePointer<UnsafeAtomic<UInt64>.Storage> // crash-allow: fixed allocation of atomics; every access is an atomic operation
    private var wordCount: Int { capacity * Self.stride }
    private let cursor = Atomic<UInt>(0)
    private let dropped = Atomic<UInt64>(0)

    /// A table of `capacity` entries (clamped to 1...256).
    public init(capacity: Int = InputLatencySlotTable.defaultCapacity) {
        self.capacity = min(max(capacity, 1), 256)
        let count = self.capacity * Self.stride
        words = UnsafeMutableRawPointer
            .allocate(byteCount: count * MemoryLayout<UnsafeAtomic<UInt64>.Storage>.stride, alignment: Self.lineBytes)
            .bindMemory(to: UnsafeAtomic<UInt64>.Storage.self, capacity: count)
        for word in 0..<count { (words + word).initialize(to: UnsafeAtomic<UInt64>.Storage(0)) }
    }

    deinit {
        words.deinitialize(count: wordCount)
        UnsafeMutableRawPointer(words).deallocate()
    }

    /// Inputs refused because every entry was open.
    public var droppedCount: UInt64 {
        dropped.load(ordering: .relaxed)
    }

    /// Opens a slot for one input and stamps its ``InputStage/generated`` stage.
    ///
    /// - Parameters:
    ///   - kind: What the person did.
    ///   - target: The view it landed in.
    ///   - entrypoint: A person's input or a synthetic one.
    ///   - generated: The OS event time (`CLOCK_UPTIME_RAW` ns, as `NSEvent.timestamp`) of the
    ///     oldest event the slot covers; later stages are stored relative to it, so it must be
    ///     the earliest time the slot records, and not 0.
    ///   - keyCode: The virtual key code of a key input (pairs its press and release), else 0.
    /// - Returns: The slot's token, or nil when `generated` is 0 or the table is full (a full
    ///   table counts the input in ``droppedCount``).
    // perf-hot: 0.1us key-dispatch
    public func begin(kind: InputEventKind, target: InputTarget, entrypoint: InputEntrypoint,
                      generated: UInt64, keyCode: UInt16 = 0) -> InputLatencyToken? {
        guard generated != 0 else { return nil }
        let start = cursor.wrappingAdd(1, ordering: .relaxed).oldValue
        for probe in 0..<capacity {
            let index = Int(truncatingIfNeeded: (start &+ UInt(probe)) % UInt(capacity))
            let state = atomic(index, Self.stateWord)
            let current = state.load(ordering: .relaxed)
            guard current & 0xFF == Phase.free.rawValue else { continue }
            let generation = Self.nextGeneration(after: current >> 8)
            let claimed = state.compareExchange(expected: current, desired: generation << 8 | Phase.initializing.rawValue,
                                                ordering: .acquiring).exchanged
            guard claimed else { continue }
            let tag = generation << Self.deltaBits
            atomic(index, Self.baseWord).store(generated, ordering: .relaxed)
            atomic(index, Self.keyCodeWord).store(UInt64(keyCode), ordering: .relaxed)
            atomic(index, Self.metaWord).store(tag | Self.meta(kind: kind, target: target, entrypoint: entrypoint), ordering: .relaxed)
            for offset in 0..<Self.stageCount {
                atomic(index, Self.firstStageWord + offset).store(tag, ordering: .relaxed)
            }
            atomic(index, Self.firstStageWord + Int(InputStage.generated.rawValue)).store(tag | 1, ordering: .relaxed)
            state.store(generation << 8 | Phase.open.rawValue, ordering: .releasing)
            return InputLatencyToken(index: index, generation: generation)
        }
        dropped.wrappingAdd(1, ordering: .relaxed)
        return nil
    }

    /// Stamps `stage` of the slot `token` names at `nanos`, from any thread, once.
    ///
    /// - Returns: Whether it wrote: false when the stage was already stamped, `nanos` is 0, or
    ///   the slot was closed (or its entry now holds another input). A mark that races the slot's
    ///   ``close(_:)`` may return true and still miss the closed slot, as an input that arrives
    ///   after its frame.
    // perf-hot: 0.05us key-dispatch
    @discardableResult
    public func mark(_ token: InputLatencyToken, _ stage: InputStage, at nanos: UInt64) -> Bool {
        let index = token.index
        guard nanos != 0, index < capacity else { return false }
        // Acquire pairs with begin's release of the open state: the base and the reset stage words
        // of this generation are visible from here on.
        let state = atomic(index, Self.stateWord).load(ordering: .acquiring)
        guard state == token.generation << 8 | Phase.open.rawValue else { return false }
        let base = atomic(index, Self.baseWord).load(ordering: .relaxed)
        let delta = nanos > base ? min(nanos - base, Self.deltaMask - 1) : 0
        let tag = token.generation << Self.deltaBits
        return atomic(index, Self.firstStageWord + Int(stage.rawValue))
            .compareExchange(expected: tag, desired: tag | (delta + 1), ordering: .relaxed).exchanged
    }

    /// Sets how the slot's presented time was found.
    @discardableResult
    public func setPresentationSource(_ token: InputLatencyToken, _ source: InputPresentationSource) -> Bool {
        updateMeta(token) { meta in
            meta & ~(0x7 << 20) | UInt64(source.rawValue) << 20
        }
    }

    /// Sets the view the input landed in once its dispatch knows it (the layout took a scroll the view under the
    /// pointer would have had).
    @discardableResult
    public func setTarget(_ token: InputLatencyToken, _ target: InputTarget) -> Bool {
        updateMeta(token) { meta in
            meta & ~(0xFF << 8) | UInt64(target.rawValue) << 8
        }
    }

    /// Records that the input changed a layer or its contents (Chrome `caused_frame_update`).
    @discardableResult
    public func setCausedFrameUpdate(_ token: InputLatencyToken) -> Bool {
        updateMeta(token) { meta in meta | 1 << 23 }
    }

    /// Records that the frame showing the input went to a variable-refresh display.
    @discardableResult
    public func setVariableRefresh(_ token: InputLatencyToken) -> Bool {
        updateMeta(token) { meta in meta | 1 << 19 }
    }

    /// The time `stage` of the slot `token` names was stamped at, from any thread, without
    /// closing it: nil when the stage is not stamped yet or the slot is not open in the token's
    /// generation.
    // perf-hot: 0.05us key-dispatch
    public func time(_ token: InputLatencyToken, _ stage: InputStage) -> UInt64? {
        let index = token.index
        guard index < capacity,
              atomic(index, Self.stateWord).load(ordering: .acquiring) == token.generation << 8 | Phase.open.rawValue
        else { return nil }
        let base = atomic(index, Self.baseWord).load(ordering: .relaxed)
        let word = atomic(index, Self.firstStageWord + Int(stage.rawValue)).load(ordering: .relaxed)
        let stamped = word & Self.deltaMask
        guard word >> Self.deltaBits == token.generation, stamped != 0 else { return nil }
        return base &+ (stamped - 1)
    }

    /// Adds `count` coalesced OS events to the slot (saturating at `UInt16.max`).
    @discardableResult
    public func addCoalesced(_ token: InputLatencyToken, _ count: UInt16) -> Bool {
        updateMeta(token) { meta in
            let current = UInt16(truncatingIfNeeded: meta >> 24)
            let (sum, overflow) = current.addingReportingOverflow(count)
            return meta & ~(0xFFFF << 24) | UInt64(overflow ? UInt16.max : sum) << 24
        }
    }

    /// Takes the slot `token` names out of the table and returns it; the entry is free again.
    /// Marks that arrive after the close are refused.
    ///
    /// - Returns: The finished slot, or nil when the token's slot is not open (closed already,
    ///   or never opened).
    // perf-hot: 0.2us key-dispatch
    public func close(_ token: InputLatencyToken) -> InputLatencySlot? {
        let index = token.index
        guard index < capacity else { return nil }
        let generation = token.generation
        let state = atomic(index, Self.stateWord)
        let closing = state.compareExchange(expected: generation << 8 | Phase.open.rawValue,
                                            desired: generation << 8 | Phase.closing.rawValue,
                                            ordering: .acquiring).exchanged
        guard closing else { return nil }
        let meta = atomic(index, Self.metaWord).load(ordering: .relaxed)
        let base = atomic(index, Self.baseWord).load(ordering: .relaxed)
        var slot = InputLatencySlot(
            kind: InputEventKind(rawValue: UInt8(truncatingIfNeeded: meta)) ?? .keyPress,
            target: InputTarget(rawValue: UInt8(truncatingIfNeeded: meta >> 8)) ?? .other,
            entrypoint: InputEntrypoint(rawValue: UInt8(truncatingIfNeeded: meta >> 16 & 0x7)) ?? .person,
            presentationSource: InputPresentationSource(rawValue: UInt8(truncatingIfNeeded: meta >> 20 & 0x7)) ?? .estimatedVsync,
            causedFrameUpdate: meta >> 23 & 1 == 1,
            isVariableRefresh: meta >> 19 & 1 == 1,
            coalescedCount: UInt16(truncatingIfNeeded: meta >> 24),
            keyCode: UInt16(truncatingIfNeeded: atomic(index, Self.keyCodeWord).load(ordering: .relaxed))
        )
        for offset in 0..<Self.stageCount {
            let word = atomic(index, Self.firstStageWord + offset).load(ordering: .relaxed)
            let stamped = word & Self.deltaMask
            guard word >> Self.deltaBits == generation, stamped != 0,
                  let stage = InputStage(rawValue: UInt8(truncatingIfNeeded: offset)) else { continue }
            slot[stage] = base &+ (stamped - 1)
        }
        state.store(generation << 8 | Phase.free.rawValue, ordering: .releasing)
        return slot
    }

    // MARK: words

    @inline(__always)
    private func atomic(_ index: Int, _ word: Int) -> UnsafeAtomic<UInt64> {
        UnsafeAtomic(at: words + (index * Self.stride + word))
    }

    /// The next generation after `generation`, never 0 (so no token is 0).
    private static func nextGeneration(after generation: UInt64) -> UInt64 {
        let next = (generation &+ 1) & generationMask
        return next == 0 ? 1 : next
    }

    /// Meta bits: kind 0-7, target 8-15, entrypoint 16-18, variable refresh 19, presentation
    /// source 20-22, caused frame update 23, coalesced count 24-39; the generation sits above them
    /// in 40-63.
    private static func meta(kind: InputEventKind, target: InputTarget, entrypoint: InputEntrypoint) -> UInt64 {
        UInt64(kind.rawValue) | UInt64(target.rawValue) << 8 | UInt64(entrypoint.rawValue) << 16
            | UInt64(InputPresentationSource.estimatedVsync.rawValue) << 20 | 1 << 24
    }

    /// Applies `change` to the meta word of `token`'s slot while that slot holds the token's input.
    private func updateMeta(_ token: InputLatencyToken, _ change: (UInt64) -> UInt64) -> Bool {
        let index = token.index
        guard index < capacity,
              atomic(index, Self.stateWord).load(ordering: .acquiring) == token.generation << 8 | Phase.open.rawValue
        else { return false }
        let word = atomic(index, Self.metaWord)
        var current = word.load(ordering: .relaxed)
        while current >> Self.deltaBits == token.generation {
            let changed = change(current & Self.deltaMask) & Self.deltaMask | token.generation << Self.deltaBits
            let (exchanged, original) = word.weakCompareExchange(expected: current, desired: changed, ordering: .relaxed)
            if exchanged { return true }
            current = original
        }
        return false
    }
}
