import CmuxNextCompat
import Foundation

/// What the burst bench (scripts/cmux-next/burst-bench.py) reads besides the action signposts, through
/// `debug.burst` (``control(_:facts:)``, DEBUG and bench builds).
///
/// It records what each press of a person did, keyed by the timestamp of the key event that ran it
/// (`event_s`, the press time the bench gave that key): a refusal they saw, a Cmd-W that closed tabs
/// (which ones, and whether that emptied the pane), or one that closed nothing by design (the close
/// guard swallowed it, or it cancelled a creation still on its way). For terminals it records each
/// grid that went to a PTY (the attach driver's claim, never a resize the driver dropped), the
/// stream's echo of that grid (the daemon applied it), and the terminal's first output after the echo.
///
/// Only `debug.burst start` arms it, so a mark outside a bench's burst costs one relaxed atomic load and
/// records nothing. A Release build compiles every mark out: what ships makes no log system call and
/// takes no lock, per pane or per frame. Times are `CLOCK_UPTIME_RAW` nanoseconds, the clock of
/// `NSEvent.timestamp` and of the signposts' `machTimestamp`, so marks from any thread compare with the
/// presses. A recording keeps at most ``capacity`` events and counts the rest as dropped. The app makes
/// one and passes it to its mark sites; tests make their own:
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

        mutating func append(_ event: Event) {
            if events.count < BurstTrace.capacity { events.append(event) } else { dropped += 1 }
        }
    }

    private let armed = Atomic<Bool>(false)
    // A lock, not an actor: marks come synchronously from the main actor, from each attach driver's
    // effect applier and from every terminal's output stream, where an actor would add a Task hop per
    // mark and reorder them (lock carve-out).
    private let state = Mutex(State())

    /// A trace that records nothing until `debug.burst start` (``control(_:facts:)``).
    public init() {}

    /// Whether a recording runs (always false in a Release build). Mark sites check it before anything else.
    public var isArmed: Bool {
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
        #if DEBUG || CMUX_BENCH_HOOKS
        guard isArmed else { return }
        let event = Event(kind: kind, at: Self.now(), input: input)
        state.withLock { $0.append(event) }
        #endif
    }

    /// A person's Cmd-W closed `tabs`, while a recording runs.
    ///
    /// - Parameters:
    ///   - tabs: The ids of the tabs it closed (the topology's tab ids).
    ///   - emptiesPane: Whether the close left the pane with no tab, so the pane closes too.
    ///   - input: The timestamp of the key event that ran it, as for ``mark(_:input:)``.
    public func closed(tabs: [String], emptiesPane: Bool, input: Double?) {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard isArmed else { return }
        let event = Event(kind: .closed, at: Self.now(), input: input, tabs: tabs, emptiesPane: emptiesPane)
        state.withLock { $0.append(event) }
        #endif
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
        #if DEBUG || CMUX_BENCH_HOOKS
        guard isArmed else { return }
        let event = Event(kind: .ptyGrid, at: Self.now(), surface: surface, cols: cols, rows: rows, expectsEcho: expectsEcho)
        let grid = Grid(cols: cols, rows: rows)
        state.withLock { state in
            state.append(event)
            guard expectsEcho else { return }
            state.unechoed[surface] = Array((state.unechoed[surface, default: []] + [grid]).suffix(Self.pendingEchoes))
        }
        #endif
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
        #if DEBUG || CMUX_BENCH_HOOKS
        guard isArmed else { return }
        let at = Self.now()
        let grid = Grid(cols: cols, rows: rows)
        state.withLock { state in
            guard let sent = state.unechoed[surface], let index = sent.firstIndex(of: grid) else { return }
            state.unechoed[surface] = Array(sent.dropFirst(index + 1))
            state.append(Event(kind: .gridEcho, at: at, surface: surface, cols: cols, rows: rows))
            state.awaitingOutput.insert(surface)
        }
        #endif
    }

    /// `surface` printed, while a recording runs: marked as ``Kind/firstOutput`` when it is the first
    /// output after the stream echoed a grid this view sent, else nothing (output already on its way
    /// before the daemon applied the grid arrives before the echo).
    ///
    /// - Parameter surface: The daemon surface of the terminal.
    public func output(surface: UInt64) {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard isArmed else { return }
        let at = Self.now()
        state.withLock { state in
            guard state.awaitingOutput.remove(surface) != nil else { return }
            state.append(Event(kind: .firstOutput, at: at, surface: surface))
        }
        #endif
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Clears the record and arms a new recording.
    func start() {
        state.withLock { $0 = State() }
        armed.store(true, ordering: .relaxed)
    }

    /// Disarms and returns what the recording kept, oldest first, and how many marks it dropped.
    func stop() -> (events: [Event], dropped: Int) {
        armed.store(false, ordering: .relaxed)
        return state.withLock { state in
            defer { state = State() }
            return (state.events, state.dropped)
        }
    }
    #endif
}
