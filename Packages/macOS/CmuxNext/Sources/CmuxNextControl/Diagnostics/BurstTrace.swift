import CmuxNextCompat
import Foundation

/// What the burst bench (scripts/cmux-next/burst-bench.py) reads besides the action signposts, through
/// `debug.burst` (``control(_:facts:)``, DEBUG and bench builds).
///
/// It records the refusals a person saw, the Cmd-W presses that closed nothing by design (the close
/// guard swallowed them, or they cancelled a creation still on its way), each terminal grid sent to its
/// PTY, and that terminal's first output after it (the TUI's redraw at the new size).
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
/// trace.gridSent(surface: 7, cols: 100, rows: 30)
/// trace.output(surface: 7)
/// let record = trace.control(["action": .string("stop")])  // events: pty_grid, first_output
/// ```
public nonisolated final class BurstTrace: Sendable {
    /// What a mark records.
    public enum Kind: String, Sendable {
        /// A refusal the person saw (the refusal HUD).
        case refusal
        /// A person's Cmd-W the close guard swallowed: it came quickly after one that emptied its pane,
        /// so it closes nothing and shows nothing (`TabCloseGuard.swallowsCmdW`).
        case closeSwallowed = "close_swallowed"
        /// A Cmd-W that cancelled the creation it would have closed (Cmd-D, then Cmd-W at once): neither
        /// press changes the layout (`DaemonService.cancelCreation(tab:)`).
        case creationCancelled = "creation_cancelled"
        /// A terminal grid went to its PTY (``BurstTrace/gridSent(surface:cols:rows:)``).
        case ptyGrid = "pty_grid"
        /// The first output of a terminal after a grid went to its PTY (``BurstTrace/output(surface:)``).
        case firstOutput = "first_output"
    }

    /// One mark.
    struct Event: Sendable {
        let kind: Kind
        /// `CLOCK_UPTIME_RAW` nanoseconds.
        let at: UInt64
        /// The PTY surface (grid and output marks).
        var surface: UInt64?
        var cols: Int?
        var rows: Int?
    }

    /// Events one recording keeps (a burst of 20 presses in STRESS sends a few hundred grids).
    public static let capacity = 20_000

    private struct State {
        var events: [Event] = []
        var dropped = 0
        /// Surfaces whose grid went to the PTY and whose first output after it has not come yet.
        var awaitingOutput: Set<UInt64> = []

        mutating func append(_ event: Event) {
            if events.count < BurstTrace.capacity { events.append(event) } else { dropped += 1 }
        }
    }

    private let armed = Atomic<Bool>(false)
    // A lock, not an actor: marks come synchronously from the main actor and from every terminal's
    // output stream, where an actor would add a Task hop per mark and reorder them (lock carve-out).
    private let state = Mutex(State())

    /// A trace that records nothing until `debug.burst start` (``control(_:facts:)``).
    public init() {}

    /// Whether a recording runs (always false in a Release build). Mark sites check it before anything else.
    public var isArmed: Bool {
        #if DEBUG
        armed.load(ordering: .relaxed)
        #else
        false
        #endif
    }

    /// Records `kind` (a refusal, a swallowed or cancelling Cmd-W) now, while a recording runs.
    ///
    /// - Parameter kind: ``Kind/refusal``, ``Kind/closeSwallowed`` or ``Kind/creationCancelled``; the
    ///   terminal kinds have their own calls, which carry the surface.
    public func mark(_ kind: Kind) {
        #if DEBUG
        guard isArmed else { return }
        let event = Event(kind: kind, at: Self.now())
        state.withLock { $0.append(event) }
        #endif
    }

    /// A grid of `cols` x `rows` went to the PTY of `surface`, while a recording runs; the surface's
    /// next ``output(surface:)`` is marked as the first after it.
    ///
    /// - Parameters:
    ///   - surface: The daemon surface of the terminal.
    ///   - cols: The grid's columns.
    ///   - rows: The grid's rows.
    public func gridSent(surface: UInt64, cols: Int, rows: Int) {
        #if DEBUG
        guard isArmed else { return }
        let event = Event(kind: .ptyGrid, at: Self.now(), surface: surface, cols: cols, rows: rows)
        state.withLock { state in
            state.append(event)
            state.awaitingOutput.insert(surface)
        }
        #endif
    }

    /// `surface` printed, while a recording runs: marked as ``Kind/firstOutput`` when it is the first
    /// output after a grid went to its PTY, else nothing.
    ///
    /// - Parameter surface: The daemon surface of the terminal.
    public func output(surface: UInt64) {
        #if DEBUG
        guard isArmed else { return }
        let at = Self.now()
        state.withLock { state in
            guard state.awaitingOutput.remove(surface) != nil else { return }
            state.append(Event(kind: .firstOutput, at: at, surface: surface))
        }
        #endif
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    #if DEBUG
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
