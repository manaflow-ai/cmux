import CmuxNextCompat
import CmuxNextInputCore
import Darwin
import ObjectiveC

/// One terminal surface's key-to-echo stage, cheap enough for every build: one atomic word holds the
/// key that waits for its echo and how far it got.
///
/// - ``keyDown()`` (main thread) arms the key the app is dispatching; a key still waiting closes as
///   ``TerminalEchoEvent/superseded``.
/// - ``outputParsed()`` (the output lane, after each chunk) marks the first chunk after the key
///   ``TerminalEchoEvent/echoParsed``. With no key waiting it costs one relaxed load.
/// - ``contentsSet()`` (any thread: the main thread now, Ghostty's presenting thread once frames are
///   set off main) marks the first frame after that parse ``TerminalEchoEvent/contentSubmitted``.
///   The layer hook reaches it only while the shared ``TerminalContentsGate`` is open.
/// - No frame within ``window`` of the key closes it as ``TerminalEchoEvent/noEcho`` (or
///   ``TerminalEchoEvent/noFrame`` when the echo was parsed).
///
/// Each transition is one atomic exchange or compare-exchange, so exactly one thread reports each
/// event and the gate is entered and left in pairs. As
/// Chromium's compositor frame reporter attributes an event to the first frame that presents its
/// update and reports the rest without one (cc/metrics/compositor_frame_reporter.cc), the first
/// parsed chunk and the first frame after it stand for the echo.
public nonisolated final class TerminalEchoStage: Sendable {
    /// How long a key waits for its echo's frame.
    public static let window: Duration = .milliseconds(500)

    private nonisolated enum Phase: UInt64 {
        case idle = 0
        case awaitingEcho = 1
        case awaitingContents = 2
    }

    /// The waiting key's token in bits 32-63 and its ``Phase`` in bits 0-7; 0 when no key waits.
    private let state = Atomic<UInt64>(0)
    private let sink: any TerminalEchoLatencySink
    private let gate: TerminalContentsGate
    private let deadline: any TerminalEchoDeadline
    private let now: @Sendable () -> UInt64

    /// - Parameters:
    ///   - sink: Where the events go.
    ///   - gate: The contents hook's gate, shared by every surface of the process.
    ///   - deadline: Closes a key after ``window``.
    ///   - now: `CLOCK_UPTIME_RAW` nanoseconds (the clock of `NSEvent.timestamp`).
    public init(sink: any TerminalEchoLatencySink, gate: TerminalContentsGate, deadline: any TerminalEchoDeadline,
                now: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.sink = sink
        self.gate = gate
        self.deadline = deadline
        self.now = now
    }

    /// A key reached the terminal: its echo is awaited from here (the sink's dispatching key; none
    /// when the app tracks none).
    @MainActor
    public func keyDown() {
        guard let token = sink.dispatchingKey else { return }
        let previous = state.exchange(Self.word(token, .awaitingEcho), ordering: .acquiringAndReleasing)
        end(previous, unparsed: .superseded, parsed: .superseded)
        deadline.schedule(after: Self.window) { [weak self] in self?.expire(token) }
    }

    /// The output lane parsed a chunk. Idle: one relaxed load.
    // perf-hot: 0.05us terminal-key
    public func outputParsed() {
        let word = state.load(ordering: .relaxed)
        guard Self.phase(word) == .awaitingEcho else { return }
        let at = now()
        // The gate opens before the frame can be awaited, so no frame set after the parse slips past it.
        gate.enter()
        guard state.compareExchange(expected: word, desired: word & ~0xFF | Phase.awaitingContents.rawValue,
                                    ordering: .releasing).exchanged else {
            gate.leave()
            return
        }
        sink.terminalEcho(Self.token(word), .echoParsed, at: at)
    }

    /// Ghostty set the layer's contents (a finished frame). Reached only while the gate is open.
    // perf-hot: 0.05us terminal-key
    public func contentsSet() {
        // Acquire pairs with the parse's release: this time is read after the parse's.
        let word = state.load(ordering: .acquiring)
        guard Self.phase(word) == .awaitingContents,
              state.compareExchange(expected: word, desired: 0, ordering: .relaxed).exchanged else { return }
        gate.leave()
        sink.terminalEcho(Self.token(word), .contentSubmitted, at: now())
    }

    /// The surface closes: a waiting key ends as ``TerminalEchoEvent/surfaceClosed``.
    public func close() {
        let previous = state.exchange(0, ordering: .acquiringAndReleasing)
        end(previous, unparsed: .surfaceClosed, parsed: .surfaceClosed)
        deadline.cancel()
    }

    /// The deadline of `token`'s key ran out. A key that already ended, or a newer key, is left alone.
    func expire(_ token: InputLatencyToken) {
        let word = state.load(ordering: .acquiring)
        guard word != 0, Self.token(word) == token,
              state.compareExchange(expected: word, desired: 0, ordering: .relaxed).exchanged else { return }
        end(word, unparsed: .noEcho, parsed: .noFrame)
    }

    /// Reports the end of the key `word` held: `unparsed` when its echo was not parsed yet,
    /// `parsed` when it waited for the frame (which also leaves the gate).
    private func end(_ word: UInt64, unparsed: TerminalEchoEvent, parsed: TerminalEchoEvent) {
        switch Self.phase(word) {
        case .idle: return
        case .awaitingEcho: sink.terminalEcho(Self.token(word), unparsed, at: now())
        case .awaitingContents:
            gate.leave()
            sink.terminalEcho(Self.token(word), parsed, at: now())
        }
    }

    private static func word(_ token: InputLatencyToken, _ phase: Phase) -> UInt64 {
        UInt64(token.rawValue) << 32 | phase.rawValue
    }

    private static func token(_ word: UInt64) -> InputLatencyToken {
        InputLatencyToken(rawValue: UInt32(truncatingIfNeeded: word >> 32))
    }

    private static func phase(_ word: UInt64) -> Phase {
        Phase(rawValue: word & 0xFF) ?? .idle
    }

    // MARK: Layer association

    /// The associated-object key: the stage class object, one stable address readable from any thread.
    private static var associationKey: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(TerminalEchoStage.self as AnyObject).toOpaque())
    }

    /// Ties this stage to the layer Ghostty presents the surface's frames in.
    func attach(to layer: AnyObject) {
        objc_setAssociatedObject(layer, Self.associationKey, self, .OBJC_ASSOCIATION_RETAIN)
    }

    /// The stage tied to `layer`, if any (read only while the gate is open).
    static func attached(to layer: AnyObject) -> TerminalEchoStage? {
        objc_getAssociatedObject(layer, associationKey) as? TerminalEchoStage
    }
}

/// The terminals whose key echo was parsed and whose frame is not set yet, across every surface:
/// the `setContents:` hook reads ``isOpen`` (one relaxed load) and does nothing more while it is 0.
public nonisolated final class TerminalContentsGate: Sendable {
    private let pending = Atomic<Int>(0)

    public init() {}

    /// Some surface waits for the frame of a key's echo.
    var isOpen: Bool { pending.load(ordering: .relaxed) > 0 }

    func enter() { pending.wrappingAdd(1, ordering: .relaxed) }
    func leave() { pending.wrappingSubtract(1, ordering: .relaxed) }
}
