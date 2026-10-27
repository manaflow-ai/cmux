import CmuxNextCompat
import CmuxNextSignposts
public import CmuxNextTrace
import Foundation

/// What the burst bench (scripts/cmux-next/burst-bench.py) reads besides the action signposts: each mark is a
/// ``SignpostName/burstEvent`` ring instant in every build while the `burst` trace category records, and
/// `debug.burst` (``control(_:facts:)``, DEBUG and bench builds) also keeps the marks it records as a list.
///
/// It records what each press of a person did, keyed by the timestamp of the key event that ran it
/// (`event_s`, the press time the bench gave that key): a refusal they saw, a Cmd-W that closed tabs
/// (which ones, and whether that emptied the pane), or one that closed nothing by design (the close
/// guard swallowed it, or it cancelled a creation still on its way). For terminals it records each
/// grid that went to a PTY (the attach driver's claim, never a resize the driver dropped), the
/// stream's echo of that grid (the daemon applied it), and the terminal's first output after the echo.
///
/// A mark while neither records costs three relaxed atomic loads and records nothing: no log system call and
/// no lock, per pane or per frame. The ring takes no lock either (Chrome's `TRACE_EVENT_INSTANT` under a
/// disabled-by-default category, base/trace_event/trace_event.h). The echo matching takes the state lock for a
/// sent grid and an announced one while one records, and for an output only between an echo and that
/// surface's first output after it, so a recording never puts every terminal's output on one lock. The matching
/// belongs to the recording that sent the grid: the first mark after the recordings stop drops it, so an echo
/// that comes later never matches a later recording's announce of the same size. Times are `CLOCK_UPTIME_RAW` nanoseconds, the clock of `NSEvent.timestamp` and
/// of the signposts' `machTimestamp`, so marks from any thread compare with the presses. A `debug.burst`
/// recording keeps at most ``capacity`` events and counts the rest as dropped. The app makes one and passes
/// it to its mark sites; tests make their own:
///
/// ```swift
/// let trace = BurstTrace()
/// _ = trace.control(["action": .string("start")])
/// trace.gridSent(surface: 7, cols: 100, rows: 30, expectsEcho: true)
/// trace.gridAnnounced(surface: 7, cols: 100, rows: 30)
/// trace.output(surface: 7)
/// let record = trace.control(["action": .string("stop")])  // events: pty_grid, grid_echo, first_output
/// ```
public nonisolated final class BurstTrace: Sendable {
    /// What a mark records.
    public enum Kind: String, Sendable {
        /// A refusal the person saw (the refusal HUD).
        case refusal
        /// A person's Cmd-W that closed nothing and showed nothing. No build emits it since a Cmd-W is
        /// aimed at the pane on screen when it was pressed (`PaneCloseAim`: a press aimed at an emptied
        /// pane shows the refusal HUD, ``refusal``); kept so the bench reads older builds' traces.
        case closeSwallowed = "close_swallowed"
        /// A Cmd-W that cancelled the creation it would have closed (Cmd-D, then Cmd-W at once): neither
        /// press changes the layout (`DaemonService.cancelCreation(tab:)`).
        case creationCancelled = "creation_cancelled"
        /// A person's Cmd-W closed tabs (``BurstTrace/closed(tabs:emptiesPane:input:)``).
        case closed
        /// A terminal grid went to its PTY (``BurstTrace/gridSent(surface:cols:rows:expectsEcho:)``).
        case ptyGrid = "pty_grid"
        /// The terminal's stream announced a grid this view sent: the daemon applied it
        /// (``BurstTrace/gridAnnounced(surface:cols:rows:)``).
        case gridEcho = "grid_echo"
        /// The first output of a terminal after the echo of a grid it sent (``BurstTrace/output(surface:)``).
        case firstOutput = "first_output"

        /// The kind's number in bits 0-7 of a ``SignpostName/burstEvent`` record's `arg0`. Fixed: rings written by
        /// an older build decode with the same numbers, and a new kind takes the next one.
        public var traceCode: UInt64 {
            switch self {
            case .refusal: 1
            case .closeSwallowed: 2
            case .creationCancelled: 3
            case .closed: 4
            case .ptyGrid: 5
            case .gridEcho: 6
            case .firstOutput: 7
            }
        }
    }

    /// One mark.
    struct Event: Sendable {
        let kind: Kind
        /// `CLOCK_UPTIME_RAW` nanoseconds.
        let at: UInt64
        /// The timestamp (seconds, `NSEvent.timestamp`) of the person's input event the mark answers.
        var input: Double?
        /// The PTY surface (grid and output marks).
        var surface: UInt64?
        var cols: Int?
        var rows: Int?
        /// Whether the daemon will echo a sent grid (it differs from the grid the stream last announced).
        var expectsEcho: Bool?
        /// The tabs a ``Kind/closed`` press closed.
        var tabs: [String]?
        /// Whether that close emptied its pane (the pane goes with it).
        var emptiesPane: Bool?
    }

    /// A terminal grid (cols x rows).
    private struct Grid: Hashable {
        let cols: Int
        let rows: Int
    }

    /// Events one recording keeps (a burst of 20 presses in STRESS sends a few hundred grids).
    public static let capacity = 20_000
    /// Grids one surface sent that its stream has not echoed yet, at most (as the attach machine keeps
    /// its due echoes).
    static let pendingEchoes = 8

    private struct State {
        var events: [Event] = []
        var dropped = 0
        /// Grids each surface sent that the stream has not echoed yet, oldest first.
        var unechoed: [UInt64: [Grid]] = [:]
        /// Surfaces whose sent grid the stream echoed and whose first output after it has not come yet.
        var awaitingOutput: Set<UInt64> = []

        /// Keeps `event` for `debug.burst` while it records (`keep`), up to ``BurstTrace/capacity``.
        mutating func append(_ event: Event, keep: Bool) {
            guard keep else { return }
            if events.count < BurstTrace.capacity { events.append(event) } else { dropped += 1 }
        }
    }

    /// Whether `debug.burst` records (only its `start` sets it, in DEBUG and bench builds).
    private let armed = Atomic<Bool>(false)
    /// The echo matching's entries (`State.unechoed` surfaces plus `State.awaitingOutput`), stored under the lock and
    /// read without it: 0 lets a mark with no recording skip the lock.
    private let matching = Atomic<Int>(0)
    /// `State.awaitingOutput.count`, stored under the lock and read without it: 0 lets an output skip the lock.
    private let awaiting = Atomic<Int>(0)
    /// Where each mark's ring instant goes.
    private let trace: TraceRuntime
    // A lock, not an actor: marks come synchronously from the main actor, from each attach driver's
    // effect applier and from every terminal's output stream, where an actor would add a Task hop per
    // mark and reorder them (lock carve-out).
    private let state = Mutex(State())

    /// A trace that records nothing until `debug.burst start` (``control(_:facts:)``) or a trace recording turns
    /// the `burst` category on.
    ///
    /// - Parameter trace: The runtime the ``SignpostName/burstEvent`` instants go to (tests pass their own).
    public init(trace: TraceRuntime = .shared) {
        self.trace = trace
    }

    /// Whether a recording runs: `debug.burst` (DEBUG and bench builds) or a trace recording with the `burst`
    /// category on (every build). Mark sites need not check it: each mark does, and a mark with no recording
    /// is what drops an ended recording's echo matching.
    public var isArmed: Bool { isListing || isRingRecording }

    /// Whether a trace recording has the `burst` category on.
    private var isRingRecording: Bool { trace.isEnabled(categoryBit: SignpostCategory.burst.traceBit) }

    /// Whether `debug.burst` keeps the marks as a list (always false in a Release build).
    private var isListing: Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        armed.load(ordering: .relaxed)
        #else
        false
        #endif
    }

    /// Records `kind` (a refusal, a swallowed or cancelling Cmd-W) now, while a recording runs.
    ///
    /// - Parameters:
    ///   - kind: ``Kind/refusal``, ``Kind/closeSwallowed`` or ``Kind/creationCancelled``; the other
    ///     kinds have their own calls, which carry their details.
    ///   - input: The timestamp of the person's input event that ran the press (`NSEvent.timestamp`),
    ///     nil when none is known: the bench matches the mark to its press by it.
    public func mark(_ kind: Kind, input: Double?) {
        guard recording() else { return }
        record(Event(kind: kind, at: Self.now(), input: input))
    }

    /// A person's Cmd-W closed `tabs`, while a recording runs.
    ///
    /// - Parameters:
    ///   - tabs: The ids of the tabs it closed (the topology's tab ids).
    ///   - emptiesPane: Whether the close left the pane with no tab, so the pane closes too.
    ///   - input: The timestamp of the key event that ran it, as for ``mark(_:input:)``.
    public func closed(tabs: [String], emptiesPane: Bool, input: Double?) {
        guard recording() else { return }
        record(Event(kind: .closed, at: Self.now(), input: input, tabs: tabs, emptiesPane: emptiesPane))
    }

    /// A grid of `cols` x `rows` went to the PTY of `surface` (the attach driver sent a claim or a
    /// take over), while a recording runs.
    ///
    /// - Parameters:
    ///   - surface: The daemon surface of the terminal.
    ///   - cols: The grid's columns.
    ///   - rows: The grid's rows.
    ///   - expectsEcho: Whether the daemon will echo it; a grid the PTY already has changes nothing and
    ///     is never echoed, so no ``Kind/gridEcho`` is looked for.
    public func gridSent(surface: UInt64, cols: Int, rows: Int, expectsEcho: Bool) {
        guard recording() else { return }
        let event = Event(kind: .ptyGrid, at: Self.now(), surface: surface, cols: cols, rows: rows, expectsEcho: expectsEcho)
        emit(event)
        let grid = Grid(cols: cols, rows: rows)
        let keep = isListing
        state.withLock { state in
            state.append(event, keep: keep)
            guard expectsEcho else { return }
            state.unechoed[surface] = Array((state.unechoed[surface, default: []] + [grid]).suffix(Self.pendingEchoes))
            publish(state)
        }
    }

    /// Surfaces whose sent grid the stream echoed and whose first output after it has not come yet
    /// (`debug.burst status`).
    public var awaitingOutputCount: Int { state.withLock { $0.awaitingOutput.count } }

    /// The stream of `surface` announced a grid of `cols` x `rows`, while a recording runs: marked as
    /// ``Kind/gridEcho`` when this view sent that grid (the daemon applied it), and the surface's next
    /// ``output(surface:)`` is then its first output at that size. Another client's grid marks nothing.
    ///
    /// - Parameters:
    ///   - surface: The daemon surface of the terminal.
    ///   - cols: The announced grid's columns.
    ///   - rows: The announced grid's rows.
    public func gridAnnounced(surface: UInt64, cols: Int, rows: Int) {
        guard recording(), matching.load(ordering: .relaxed) != 0 else { return }
        let at = Self.now()
        let grid = Grid(cols: cols, rows: rows)
        let keep = isListing
        let echo: Event? = state.withLock { state in
            guard let sent = state.unechoed[surface], let index = sent.firstIndex(of: grid) else { return nil }
            let rest = sent.dropFirst(index + 1)
            state.unechoed[surface] = rest.isEmpty ? nil : Array(rest)
            let event = Event(kind: .gridEcho, at: at, surface: surface, cols: cols, rows: rows)
            state.append(event, keep: keep)
            state.awaitingOutput.insert(surface)
            publish(state)
            return event
        }
        if let echo { emit(echo) }
    }

    /// `surface` printed, while a recording runs: marked as ``Kind/firstOutput`` when it is the first
    /// output after the stream echoed a grid this view sent, else nothing (output already on its way
    /// before the daemon applied the grid arrives before the echo).
    ///
    /// - Parameter surface: The daemon surface of the terminal.
    public func output(surface: UInt64) {
        // A surface's echo and its outputs come in order from its one stream, so its echo's store is seen here.
        guard recording(), awaiting.load(ordering: .relaxed) != 0 else { return }
        let at = Self.now()
        let keep = isListing
        let first: Event? = state.withLock { state in
            guard state.awaitingOutput.remove(surface) != nil else { return nil }
            let event = Event(kind: .firstOutput, at: at, surface: surface)
            state.append(event, keep: keep)
            publish(state)
            return event
        }
        if let first { emit(first) }
    }

    /// The terminal view of `surface` closed: its grids' echoes and its first output are no longer looked for.
    ///
    /// - Parameter surface: The daemon surface of the terminal.
    public func forget(surface: UInt64) {
        guard matching.load(ordering: .relaxed) != 0 else { return }
        state.withLock { state in
            state.unechoed[surface] = nil
            state.awaitingOutput.remove(surface)
            publish(state)
        }
    }

    /// Whether a recording runs (``isArmed``). With none, the echo matching an ended recording left goes first, so
    /// a grid it sent never matches what a later recording sees.
    private func recording() -> Bool {
        if isArmed { return true }
        if matching.load(ordering: .relaxed) != 0 { state.withLock { clearMatching(&$0) } }
        return false
    }

    /// Drops every grid waiting for its echo and every surface waiting for its first output.
    private func clearMatching(_ state: inout State) {
        state.unechoed = [:]
        state.awaitingOutput = []
        publish(state)
    }

    /// Stores the matching's sizes for the lock-free checks; called under the lock after each change.
    private func publish(_ state: State) {
        matching.store(state.unechoed.count + state.awaitingOutput.count, ordering: .relaxed)
        awaiting.store(state.awaitingOutput.count, ordering: .relaxed)
    }

    /// Writes `event`'s ring instant and keeps it for `debug.burst` while that records.
    private func record(_ event: Event) {
        emit(event)
        guard isListing else { return }
        state.withLock { $0.append(event, keep: true) }
    }

    /// The ``SignpostName/burstEvent`` instant of `event`, while the `burst` category records.
    private func emit(_ event: Event) {
        trace.event(.burstEvent, arg0: event.traceArg0, arg1: event.traceArg1)
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Clears the record and arms a new recording. The echo matching stays while a trace recording uses it too.
    func start() {
        let shared = isRingRecording
        state.withLock { state in
            (state.events, state.dropped) = ([], 0)
            if !shared { clearMatching(&state) }
        }
        armed.store(true, ordering: .relaxed)
    }

    /// Disarms and returns what the recording kept, oldest first, and how many marks it dropped. The echo matching
    /// stays while a trace recording uses it too.
    func stop() -> (events: [Event], dropped: Int) {
        armed.store(false, ordering: .relaxed)
        let shared = isRingRecording
        return state.withLock { state in
            defer {
                (state.events, state.dropped) = ([], 0)
                if !shared { clearMatching(&state) }
            }
            return (state.events, state.dropped)
        }
    }
    #endif
}

extension BurstTrace.Event {
    /// The ring record's `arg0` (``SignpostName/burstEvent``): the kind's code in bits 0-7; a grid's columns in bits
    /// 8-23, its rows in bits 24-39 and, on a sent one, bit 40 when the daemon will echo it; a close's tab count in
    /// bits 8-23 and bit 24 when it empties the pane. Each count saturates at its field.
    var traceArg0: UInt64 {
        var arg0 = kind.traceCode
        if let cols, let rows {
            arg0 |= Self.field(cols, bits: 16) << 8 | Self.field(rows, bits: 16) << 24
            if expectsEcho == true { arg0 |= 1 << 40 }
        }
        if let tabs {
            arg0 |= Self.field(tabs.count, bits: 16) << 8
            if emptiesPane == true { arg0 |= 1 << 24 }
        }
        return arg0
    }

    /// The ring record's `arg1`: the PTY surface of a grid or an output mark, else the input event's time in
    /// `CLOCK_UPTIME_RAW` nanoseconds (0 without one).
    var traceArg1: UInt64 {
        if let surface { return surface }
        guard let input, input > 0 else { return 0 }
        return UInt64(exactly: (input * 1e9).rounded()) ?? 0
    }

    /// `value` in a field of `bits` bits: 0 below 0, the field's largest value above it.
    private static func field(_ value: Int, bits: UInt64) -> UInt64 {
        min(UInt64(clamping: value), (1 << bits) - 1)
    }
}
