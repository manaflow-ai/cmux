public import Foundation
import CmuxNextCompat
import CmuxNextSignposts
import CmuxNextTrace

/// A new terminal's stages, from the New Terminal Tab action to its first visible prompt (cx-6so.58).
///
/// Every build (p09-observability task 043): the stages that run once per terminal write a
/// ``SignpostName/createTab`` instant into the trace ring (``event(_:arg1:)``): the action, the attach's
/// start, reply and end, the session's surface and a layout spring's final grid. `arg0` is the stage
/// (``Mark/traceCode``); `arg1` is the daemon surface for the attach stages, the grid for `final_grid`
/// (``gridBits(columns:rows:)``) and 0 for the others. They fall inside the new tab's `create.tab` async
/// slice (task 030), from the key's turn to its first themed frame, as Chrome marks the steps of one
/// navigation with instants beside its async `NavigationRequest` slice
/// (content/browser/renderer_host/navigation_request.cc). Off, a stage costs one relaxed load of the
/// `create` category flag; on, one 32-byte ring record with no lock, allocation or text.
///
/// DEBUG and bench builds also keep one stage timeline per `debug.new_terminal_trace` run (the `#if`
/// extension below). Disarmed (every run but a trace run) that costs a mark site one relaxed atomic load
/// of ``isArmed`` more and nothing else. ``begin()`` arms one trace; the first terminal id minted after
/// the action binds it, and every later mark is keyed by that id, or by what the id leads to: the tab's
/// surface (`tab_added` names it), and the session, output lane and layer of the view whose IO attaches
/// to that surface. Each mark records its first time only. ``finish(timedOut:)`` disarms and keeps the
/// record in a bounded ring.
///
/// Mark sites live in the daemon client, the terminal and the app, which share no injection seam, so
/// they reach this one recorder (as ``TypingLatencyProbe``). Times are `CLOCK_UPTIME_RAW` nanoseconds,
/// so marks from any thread compare.
public final class NewTerminalTrace: Sendable {
    public static let shared = NewTerminalTrace()

    public enum Mark: Int, CaseIterable, Sendable {
        case action, requestSent, reply, tabAdded, surfaceCreated, attachStart, attachReplied, attachEnd,
             firstOutputMain, firstParsed, firstContents, promptParsed, promptContents, finalGrid

        /// The mark's name in `debug.new_terminal_trace` results.
        public var name: String {
            switch self {
            case .action: "action"
            case .requestSent: "request_sent"
            case .reply: "reply"
            case .tabAdded: "tab_added"
            case .surfaceCreated: "surface_created"
            case .attachStart: "attach_start"
            case .attachReplied: "attach_replied"
            case .attachEnd: "attach_end"
            case .firstOutputMain: "first_output_main"
            case .firstParsed: "first_parsed"
            case .firstContents: "first_contents"
            case .promptParsed: "prompt_parsed"
            case .promptContents: "prompt_contents"
            case .finalGrid: "final_grid"
            }
        }

        /// The stage's number in a `create.tab` instant's `arg0`: 16 + its position, above the kinds (1...5)
        /// a stand-in instant holds there (``CreateTabInterval/Kind/traceCode``). Fixed: rings written by an
        /// older build decode with the same numbers, so a new stage goes at the end.
        public var traceCode: UInt64 { 16 + UInt64(rawValue) }
    }

    private let trace: TraceRuntime
    #if DEBUG || CMUX_BENCH_HOOKS
    private let armed = Atomic<Bool>(false)
    private let state = Mutex(State())
    #endif

    /// - Parameter trace: The runtime whose ring takes the stage instants (tests pass their own).
    init(trace: TraceRuntime = .shared) {
        self.trace = trace
    }

    /// Writes stage `mark`'s `create.tab` instant; `arg1` as the type's doc says.
    public func event(_ mark: Mark, arg1: UInt64 = 0) {
        trace.event(.createTab, arg0: mark.traceCode, arg1: arg1)
    }

    /// Stage `mark` of the terminal whose session is `session` (its final grid): the instant and, in DEBUG,
    /// the running trace's mark when `session` is the bound terminal's view.
    public func event(_ mark: Mark, session: ObjectIdentifier, arg1: UInt64 = 0) {
        event(mark, arg1: arg1)
        #if DEBUG || CMUX_BENCH_HOOKS
        guard isArmed else { return }
        let now = Self.now()
        update { record, watch in if watch.session == session { record.set(mark, now) } }
        #endif
    }

    /// The new terminal action ran (its handler's entry).
    public func markAction() {
        event(.action)
        #if DEBUG || CMUX_BENCH_HOOKS
        guard isArmed else { return }
        let now = Self.now()
        update { record, _ in record.set(.action, now) }
        #endif
    }

    /// Stage `mark` of daemon surface `surface` (the attach): the instant and, in DEBUG, the running trace's
    /// mark when `surface` is the bound terminal's.
    public func mark(_ mark: Mark, surface: UInt64) {
        event(mark, arg1: surface)
        #if DEBUG || CMUX_BENCH_HOOKS
        guard isArmed else { return }
        let now = Self.now()
        update { record, _ in if record.surface == surface { record.set(mark, now) } }
        #endif
    }

    /// A grid as one instant argument: the columns in the high 32 bits, the rows in the low 32.
    public static func gridBits(columns: Int, rows: Int) -> UInt64 {
        UInt64(UInt32(clamping: columns)) << 32 | UInt64(UInt32(clamping: rows))
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

#if DEBUG || CMUX_BENCH_HOOKS
// DEBUG and bench builds: the `debug.new_terminal_trace` timeline.
extension NewTerminalTrace {
    /// Finished traces kept for `get`.
    public static let capacity = 32
    /// OSC 133;A, the prompt start shell integration writes.
    private static let promptMarker = Data([0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x41])

    /// One trace: its keys and the first time of each mark.
    public struct Record: Sendable {
        /// The terminal id the trace bound (nil: none was minted).
        public internal(set) var terminal: String?
        /// The daemon surface of its tab (nil until `tab_added`).
        public internal(set) var surface: UInt64?
        public internal(set) var timedOut = false
        let armedAt: UInt64
        var marks = [UInt64?](repeating: nil, count: Mark.allCases.count)

        /// Milliseconds from `action` (from arming when no action ran) to `mark`; nil when it never ran.
        public func milliseconds(_ mark: Mark) -> Double? {
            guard let at = marks[mark.rawValue] else { return nil }
            let origin = marks[Mark.action.rawValue] ?? armedAt
            return Double(Int64(bitPattern: at &- origin)) / 1_000_000
        }
    }

    /// What the bound terminal's view is made of, matched by identity.
    fileprivate struct Watch {
        var io: ObjectIdentifier?
        var session: ObjectIdentifier?
        var lane: ObjectIdentifier?
        var layer: ObjectIdentifier?
    }

    fileprivate struct State {
        var current: Record?
        var watch = Watch()
        var finished: [Record] = []
        var waiter: CheckedContinuation<Void, Never>?
        var expired = false
    }

    /// Whether a trace runs. Mark sites check it before anything else.
    public var isArmed: Bool { armed.load(ordering: .relaxed) }

    /// Arms a new trace; false when one already runs.
    public func begin() -> Bool {
        let now = Self.now()
        let started = state.withLock { state -> Bool in
            guard state.current == nil else { return false }
            state.current = Record(armedAt: now)
            state.watch = Watch()
            state.expired = false
            return true
        }
        if started { armed.store(true, ordering: .relaxed) }
        return started
    }

    /// Disarms the trace and keeps its record; nil when none ran.
    public func finish(timedOut: Bool) -> Record? {
        armed.store(false, ordering: .relaxed)
        let (record, waiter) = state.withLock { state -> (Record?, CheckedContinuation<Void, Never>?) in
            guard var record = state.current else { return (nil, nil) }
            record.timedOut = timedOut
            state.current = nil
            state.watch = Watch()
            state.finished.append(record)
            if state.finished.count > Self.capacity { state.finished.removeFirst(state.finished.count - Self.capacity) }
            defer { state.waiter = nil }
            return (record, state.waiter)
        }
        waiter?.resume()
        return record
    }

    /// The last `count` finished traces, oldest first.
    public func recent(_ count: Int) -> [Record] {
        state.withLock { Array($0.finished.suffix(max(count, 0))) }
    }

    /// A terminal id was minted: the first one after the action binds the trace.
    public func bind(terminal: String) {
        guard isArmed else { return }
        update { record, _ in
            guard record.terminal == nil, record.marks[Mark.action.rawValue] != nil else { return }
            record.terminal = terminal
        }
    }

    /// A request line was written. Marks `request_sent` when it names the bound
    /// terminal, and returns that id for the `reply` mark.
    public func requestSent(_ line: Data) -> String? {
        guard isArmed else { return nil }
        let now = Self.now()
        return query { record, _ -> String? in
            guard let terminal = record.terminal, record.marks[Mark.requestSent.rawValue] == nil,
                  line.range(of: Data(terminal.utf8)) != nil else { return nil }
            record.set(.requestSent, now)
            return terminal
        } ?? nil
    }

    /// Marks `mark` for the bound terminal `terminal`.
    public func mark(_ mark: Mark, terminal: String) {
        guard isArmed else { return }
        let now = Self.now()
        update { record, _ in if record.terminal == terminal { record.set(mark, now) } }
    }

    /// The store first has the bound terminal's tab, on daemon surface `surface`.
    public func tabAdded(terminal: String, surface: UInt64) {
        guard isArmed else { return }
        let now = Self.now()
        update { record, _ in
            guard record.terminal == terminal, record.surface == nil else { return }
            record.surface = surface
            record.set(.tabAdded, now)
        }
    }

    /// The IO `io` was made for surface `surface`: a session over it is the bound terminal's view.
    public func watch(io: ObjectIdentifier, surface: UInt64) {
        guard isArmed else { return }
        update { record, watch in if record.surface == surface { watch.io = io } }
    }

    /// A session over `io` created its surface. Marks `surface_created` and watches the
    /// session, lane and layer when `io` is the watched one; returns whether it was.
    public func sessionCreated(io: ObjectIdentifier, session: ObjectIdentifier, lane: ObjectIdentifier?,
                               layer: ObjectIdentifier?) -> Bool {
        guard isArmed else { return false }
        let now = Self.now()
        return query { record, watch -> Bool in
            guard watch.io == io, watch.session == nil else { return false }
            watch = Watch(io: io, session: session, lane: lane, layer: layer)
            record.set(.surfaceCreated, now)
            return true
        } ?? false
    }

    /// The watched session replaced its surface (a later replay): watch the fresh lane and layer.
    public func surfaceSwapped(session: ObjectIdentifier, lane: ObjectIdentifier?, layer: ObjectIdentifier?) {
        guard isArmed else { return }
        update { _, watch in
            guard watch.session == session else { return }
            watch.lane = lane
            watch.layer = layer
        }
    }

    /// The session `session` took a content event (replay, snapshot or output) on the main actor.
    public func contentOnMain(session: ObjectIdentifier) {
        let now = Self.now()
        update { record, watch in if watch.session == session { record.set(.firstOutputMain, now) } }
    }

    /// The lane `lane` parsed a chunk; `data` (nil for a snapshot) is scanned for OSC 133;A.
    public func parsed(lane: ObjectIdentifier, _ data: Data?) {
        let now = Self.now()
        let prompt = data.map { $0.range(of: Self.promptMarker) != nil } ?? false
        update { record, watch in
            guard watch.lane == lane else { return }
            record.set(.firstParsed, now)
            if prompt { record.set(.promptParsed, now) }
        }
    }

    /// The layer `layer` was handed a frame. The first after a parse is `first_contents`, the
    /// first after the prompt's parse `prompt_contents`, which ends ``waitForPrompt(timeout:)``.
    public func contents(layer: ObjectIdentifier) {
        let now = Self.now()
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard var record = state.current, state.watch.layer == layer else { return nil }
            if record.marks[Mark.firstParsed.rawValue] != nil { record.set(.firstContents, now) }
            var prompted = false
            if record.marks[Mark.promptParsed.rawValue] != nil, record.marks[Mark.promptContents.rawValue] == nil {
                record.set(.promptContents, now)
                prompted = true
            }
            state.current = record
            guard prompted else { return nil }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Returns once the trace marked `prompt_contents` (true), or after `timeout` (false).
    /// The timeout is the command's own deadline, not a poll.
    public func waitForPrompt(timeout: Duration) async -> Bool {
        let deadline = Task { [self] in
            guard (try? await ContinuousClock().sleep(for: timeout)) != nil else { return }
            expire()
        }
        defer { deadline.cancel() }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                guard !state.expired, let record = state.current, record.marks[Mark.promptContents.rawValue] == nil else {
                    return true
                }
                state.waiter = waiter
                return false
            }
            if resumeNow { waiter.resume() }
        }
        return state.withLock { $0.current?.marks[Mark.promptContents.rawValue] != nil }
    }

    private func expire() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.expired = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Runs `body` on the running trace's record and watch (nothing when none runs).
    fileprivate func update(_ body: (inout Record, inout Watch) -> Void) {
        state.withLock { state in
            guard var record = state.current else { return }
            body(&record, &state.watch)
            state.current = record
        }
    }

    /// ``update(_:)`` that returns `body`'s answer; nil when no trace runs.
    private func query<Value: Sendable>(_ body: (inout Record, inout Watch) -> Value) -> Value? {
        state.withLock { state -> Value? in
            guard var record = state.current else { return nil }
            let value = body(&record, &state.watch)
            state.current = record
            return value
        }
    }
}

extension NewTerminalTrace.Record {
    /// Records `mark` at `time` unless it already ran.
    fileprivate mutating func set(_ mark: NewTerminalTrace.Mark, _ time: UInt64) {
        if marks[mark.rawValue] == nil { marks[mark.rawValue] = time }
    }
}
#endif
