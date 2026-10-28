import CmuxNextCompat
import CmuxNextInputCore
import Darwin
import ObjectiveC

/// One terminal surface's key-to-echo stages: a fixed ring of the keys that wait for their echo, one
/// atomic word each.
///
/// - ``keyDown()`` (main thread) arms the key the app is dispatching in the next ring entry. A key
///   still waiting there (the ring holds ``defaultCapacity`` keys) closes as
///   ``TerminalEchoEvent/superseded``.
/// - ``outputParsed(armedBefore:)`` (the output lane, after each chunk) marks every key that was
///   armed before the chunk reached the lane ``TerminalEchoEvent/echoParsed``. With no key waiting
///   for its echo it costs one relaxed load.
/// - ``contentsSet()`` (any thread: the main thread now, Ghostty's presenting thread once frames are
///   set off main) marks every parsed key ``TerminalEchoEvent/contentSubmitted``. The layer hook
///   calls it only while the shared ``TerminalContentsGate`` is open.
/// - A key with no frame within ``window`` closes as ``TerminalEchoEvent/noEcho`` (or
///   ``TerminalEchoEvent/noFrame`` when its echo was parsed). One deadline serves the ring: armed by
///   the first waiting key, re-armed for the oldest key left, cancelled when the last key ends.
///
/// Each transition is one atomic exchange or compare-exchange, so exactly one thread reports each
/// event and the gate is entered and left in pairs. A parse holds its key in `parsing` while it
/// reports echoParsed; frames and the deadline leave such a key alone, so a key's ending always comes
/// after its echoParsed. As Chromium's compositor frame reporter gives each event coalesced into a
/// frame that frame's presentation (cc/metrics/compositor_frame_reporter.cc), every waiting key takes
/// the chunk and the frame that follow it.
public nonisolated final class TerminalEchoStage: Sendable {
    /// How long a key waits for its echo's frame.
    public static let window: Duration = .milliseconds(500)
    private static let windowNanos: UInt64 = 500_000_000
    /// Keys a surface tracks at once; a newer key past this supersedes the oldest.
    public static let defaultCapacity = 8

    private nonisolated enum Phase: UInt64 {
        case idle = 0
        case awaitingEcho = 1
        case parsing = 2
        case awaitingContents = 3
    }

    /// One ring entry. `word`: the key's token in bits 32-63, its arm sequence in bits 8-31 and its
    /// ``Phase`` in bits 0-7, 0 when free. `armedAt` is written before the word is published.
    private nonisolated final class Entry: Sendable {
        let word = Atomic<UInt64>(0)
        let armedAt = Atomic<UInt64>(0)
    }

    private let entries: [Entry]
    /// Keys armed so far: the next key's sequence.
    private let armed = Atomic<UInt32>(0)
    /// Entries in `awaitingEcho`: the output lane's idle check.
    private let awaitingEcho = Atomic<Int>(0)
    /// Entries that are not free.
    private let outstanding = Atomic<Int>(0)
    private let deadlineArmed = Atomic<Bool>(false)
    private let closed = Atomic<Bool>(false)
    private let sink: any TerminalEchoLatencySink
    private let gate: TerminalContentsGate
    private let deadline: any TerminalEchoDeadline
    private let now: @Sendable () -> UInt64

    /// - Parameters:
    ///   - sink: Where the events go.
    ///   - gate: The contents hook's gate, shared by every surface of the process.
    ///   - deadline: Closes keys after ``window``.
    ///   - capacity: Keys tracked at once.
    ///   - now: `CLOCK_UPTIME_RAW` nanoseconds (the clock of `NSEvent.timestamp`); `nil` reads that
    ///     clock (a public default argument cannot name the internally imported Darwin clock).
    public init(sink: any TerminalEchoLatencySink, gate: TerminalContentsGate, deadline: any TerminalEchoDeadline,
                capacity: Int = TerminalEchoStage.defaultCapacity,
                now: (@Sendable () -> UInt64)? = nil) {
        entries = (0..<max(capacity, 1)).map { _ in Entry() }
        self.sink = sink
        self.gate = gate
        self.deadline = deadline
        self.now = now ?? { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    }

    /// Keys armed so far. The output lane reads it when a chunk arrives: keys armed later cannot be
    /// that chunk's echo.
    public var armedCount: UInt32 { armed.load(ordering: .relaxed) }

    /// A key reached the terminal: its echo is awaited from here (the sink's dispatching key; none
    /// when the app tracks none).
    @MainActor
    public func keyDown() {
        guard !closed.load(ordering: .relaxed), let token = sink.dispatchingKey else { return }
        let sequence = armed.wrappingAdd(1, ordering: .relaxed).oldValue
        let entry = entries[Int(sequence % UInt32(entries.count))]
        entry.armedAt.store(now(), ordering: .relaxed)
        awaitingEcho.wrappingAdd(1, ordering: .relaxed)
        let previous = entry.word.exchange(Self.packed(token, sequence, .awaitingEcho), ordering: .acquiringAndReleasing)
        if previous == 0 {
            outstanding.wrappingAdd(1, ordering: .sequentiallyConsistent)
        } else {
            end(previous, unparsed: .superseded, parsed: .superseded, at: now())
        }
        if !deadlineArmed.exchange(true, ordering: .sequentiallyConsistent) { armDeadline(after: Self.window) }
    }

    /// The output lane parsed a chunk that reached it when `armedBefore` keys had been armed
    /// (``armedCount``). Idle: one relaxed load.
    // perf-hot: 0.05us terminal-key
    public func outputParsed(armedBefore: UInt32) {
        guard awaitingEcho.load(ordering: .relaxed) > 0 else { return }
        let at = now()
        for entry in entries {
            let word = entry.word.load(ordering: .acquiring)
            let parsing = Self.inPhase(word, .parsing)
            guard Self.phase(word) == .awaitingEcho, Self.wasArmed(word, before: armedBefore),
                  entry.word.compareExchange(expected: word, desired: parsing, ordering: .acquiringAndReleasing).exchanged
            else { continue }
            awaitingEcho.wrappingSubtract(1, ordering: .relaxed)
            sink.terminalEcho(Self.token(word), .echoParsed, at: at)
            // The gate opens before the frame wait is published, so no frame set after it slips past the hook.
            gate.enter()
            if !entry.word.compareExchange(expected: parsing, desired: Self.inPhase(word, .awaitingContents),
                                           ordering: .acquiringAndReleasing).exchanged {
                // keyDown or close took the entry while echoParsed was reported; the ending is reported here.
                gate.leave()
                let ending: TerminalEchoEvent = closed.load(ordering: .acquiring) ? .surfaceClosed : .superseded
                sink.terminalEcho(Self.token(word), ending, at: now())
            }
        }
    }

    /// Ghostty set the layer's contents (a finished frame). Reached only while the gate is open.
    // perf-hot: 0.05us terminal-key
    public func contentsSet() {
        var at: UInt64 = 0
        var ended = 0
        for entry in entries {
            let word = entry.word.load(ordering: .acquiring)
            guard Self.phase(word) == .awaitingContents,
                  entry.word.compareExchange(expected: word, desired: 0, ordering: .acquiringAndReleasing).exchanged
            else { continue }
            if at == 0 { at = now() }
            gate.leave()
            sink.terminalEcho(Self.token(word), .contentSubmitted, at: at)
            ended += 1
        }
        if ended > 0 { finished(ended) }
    }

    /// The surface closes: every waiting key ends as ``TerminalEchoEvent/surfaceClosed``.
    public func close() {
        closed.store(true, ordering: .sequentiallyConsistent)
        var ended = 0
        for entry in entries {
            let previous = entry.word.exchange(0, ordering: .acquiringAndReleasing)
            guard previous != 0 else { continue }
            ended += 1
            end(previous, unparsed: .surfaceClosed, parsed: .surfaceClosed, at: now())
        }
        outstanding.wrappingSubtract(ended, ordering: .sequentiallyConsistent)
        deadlineArmed.store(false, ordering: .sequentiallyConsistent)
        deadline.cancel()
    }

    /// The deadline ran out: keys armed ``window`` ago or earlier end; the deadline is re-armed for
    /// the oldest key left.
    func expire() {
        deadlineArmed.store(false, ordering: .sequentiallyConsistent)
        let at = now()
        var ended = 0
        var oldest: UInt64?
        for entry in entries {
            let word = entry.word.load(ordering: .acquiring)
            guard word != 0 else { continue }
            let armedAt = entry.armedAt.load(ordering: .relaxed)
            let age = at >= armedAt ? at - armedAt : 0
            if age >= Self.windowNanos, Self.phase(word) != .parsing,
               entry.word.compareExchange(expected: word, desired: 0, ordering: .acquiringAndReleasing).exchanged {
                end(word, unparsed: .noEcho, parsed: .noFrame, at: at)
                ended += 1
            } else {
                oldest = min(oldest ?? armedAt, armedAt)
            }
        }
        if ended > 0 { finished(ended) }
        guard let oldest else { return }
        let age = at >= oldest ? at - oldest : 0
        // A key still being parsed past its window is looked at again in a millisecond.
        let remaining = age < Self.windowNanos ? Self.windowNanos - age : 1_000_000
        deadlineArmed.store(true, ordering: .sequentiallyConsistent)
        armDeadline(after: .nanoseconds(Int64(remaining)))
    }

    /// `count` keys ended. When none is left the deadline is dropped, so a stage whose keys all got
    /// their frame causes no wakeup; a key armed meanwhile gets its deadline back.
    private func finished(_ count: Int) {
        guard outstanding.wrappingSubtract(count, ordering: .sequentiallyConsistent).newValue == 0 else { return }
        deadlineArmed.store(false, ordering: .sequentiallyConsistent)
        deadline.cancel()
        // keyDown counts its key before it looks at `deadlineArmed`: a key it armed before the cancel is seen here.
        guard outstanding.load(ordering: .sequentiallyConsistent) > 0 else { return }
        deadlineArmed.store(true, ordering: .sequentiallyConsistent)
        armDeadline(after: Self.window)
    }

    private func armDeadline(after delay: Duration) {
        deadline.schedule(after: delay) { [weak self] in self?.expire() }
    }

    /// Reports the end of the key `word` held, which the caller took out of its entry: `unparsed`
    /// when its echo was not parsed yet, `parsed` when it waited for the frame (which also leaves
    /// the gate). A key in `parsing` is reported by its parse.
    private func end(_ word: UInt64, unparsed: TerminalEchoEvent, parsed: TerminalEchoEvent, at: UInt64) {
        switch Self.phase(word) {
        case .idle, .parsing: return
        case .awaitingEcho:
            awaitingEcho.wrappingSubtract(1, ordering: .relaxed)
            sink.terminalEcho(Self.token(word), unparsed, at: at)
        case .awaitingContents:
            gate.leave()
            sink.terminalEcho(Self.token(word), parsed, at: at)
        }
    }

    private static func packed(_ token: InputLatencyToken, _ sequence: UInt32, _ phase: Phase) -> UInt64 {
        UInt64(token.rawValue) << 32 | UInt64(sequence & 0xFF_FFFF) << 8 | phase.rawValue
    }

    /// `word` in `phase`.
    private static func inPhase(_ word: UInt64, _ phase: Phase) -> UInt64 {
        word & ~0xFF | phase.rawValue
    }

    private static func token(_ word: UInt64) -> InputLatencyToken {
        InputLatencyToken(rawValue: UInt32(truncatingIfNeeded: word >> 32))
    }

    private static func phase(_ word: UInt64) -> Phase {
        Phase(rawValue: word & 0xFF) ?? .idle
    }

    /// Whether `word`'s key was armed before `count` keys had been (24-bit sequences, wrapping).
    private static func wasArmed(_ word: UInt64, before count: UInt32) -> Bool {
        let distance = (count &- UInt32(truncatingIfNeeded: word >> 8)) & 0xFF_FFFF
        return distance != 0 && distance < 0x80_0000
    }

    // MARK: Layer association

    /// The associated-object key: the stage class's identity, one stable address readable from any
    /// thread (nil only for a 0 identity, which no type has).
    @safe private static var associationKey: UnsafeRawPointer? {
        // SAFETY: built from the identity's bits and only compared by the runtime, never
        // dereferenced; the class's metadata lives for the process, so the address is stable.
        unsafe UnsafeRawPointer(bitPattern: UInt(bitPattern: ObjectIdentifier(TerminalEchoStage.self)))
    }

    /// Ties this stage to the layer Ghostty presents the surface's frames in.
    func attach(to layer: AnyObject) {
        guard let key = unsafe Self.associationKey else { return }
        // SAFETY: the key is an address the runtime only compares (`associationKey`); the runtime
        // retains this stage on `layer` (OBJC_ASSOCIATION_RETAIN).
        unsafe objc_setAssociatedObject(layer, key, self, .OBJC_ASSOCIATION_RETAIN)
    }

    /// The stage tied to `layer`, if any (read only while the gate is open).
    static func attached(to layer: AnyObject) -> TerminalEchoStage? {
        guard let key = unsafe associationKey else { return nil }
        // SAFETY: the key is an address the runtime only compares (`associationKey`); the value is
        // an object the layer retains, and the cast checks its type.
        return unsafe objc_getAssociatedObject(layer, key) as? TerminalEchoStage
    }
}

/// The terminal keys whose echo was parsed and whose frame is not set yet, across every surface:
/// the `setContents:` hook reads ``isOpen`` (one relaxed load) and does nothing more while it is 0.
/// One per process (``GhosttyRuntime/echoStages``): a layer class's hook reads the gate it was
/// installed with.
public nonisolated final class TerminalContentsGate: Sendable {
    private let pending = Atomic<Int>(0)

    public init() {}

    /// Some surface waits for the frame of a key's echo.
    var isOpen: Bool { pending.load(ordering: .relaxed) > 0 }

    func enter() { pending.wrappingAdd(1, ordering: .relaxed) }
    func leave() { pending.wrappingSubtract(1, ordering: .relaxed) }

    /// Surfaces shown again that wait for their first frame (``TerminalShowRecord``): while 0 the hook looks
    /// up no show record. Separate from ``isOpen``, so it never opens the echo stages' path.
    private let showsPending = Atomic<Int>(0)
    var showsWaiting: Bool { showsPending.load(ordering: .relaxed) > 0 }
    func showEntered() { showsPending.wrappingAdd(1, ordering: .relaxed) }
    func showLeft() { showsPending.wrappingSubtract(1, ordering: .relaxed) }
}
