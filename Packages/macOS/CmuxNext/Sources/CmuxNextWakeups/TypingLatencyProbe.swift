import Foundation
import CmuxNextCompat
import CmuxNextSignposts

/// Opt-in keystroke-to-frame timeline for terminal keys (`CMUX_NEXT_TYPING_PROBE=<csv path>`, or key
/// flows started with ``startFlows()``). Off by default: every hop then costs one load of
/// ``isEnabled``.
///
/// Each key-down opens a sample with its own flow id (this process's pid in the high 32 bits), and up to
/// ``openCapacity`` presses are in flight at once, as Chromium gives every input event its own
/// `LatencyInfo` trace id and tracks each one to its frame (ui/latency/latency_info.h,
/// cc/metrics/event_metrics.h). A sample records the first time each later hop runs: AppKit dispatch,
/// Ghostty's write callback, the attach socket submit, the echo's decode on the attach reader, the
/// session taking it for its output lane (`output_received_ms`: off the main actor since G4, so rows
/// before 04237873b23 named this column `output_main_ms` and do not compare), its parse on the output
/// lane, and the frame Ghostty hands to the layer after that parse. The row is appended when that frame
/// lands. A press past ``openCapacity`` closes the oldest one unfinished. Times are milliseconds after
/// the event's own timestamp (seconds since boot, the same clock as `CLOCK_UPTIME_RAW`).
///
/// Output hops are exact: the daemon's `output` event names the press it echoes (`flow`), so the decode
/// marks that press (``mark(_:flow:)``), and the surface's later hops (received, parsed, contents) mark
/// only the presses open on that surface (``SurfaceFlows``) whose echo was decoded.
///
/// `commit_ms` is the end of the first main run-loop turn after dispatch, past Core Animation's commit
/// observer: the frame that carries what the key changed in an AppKit text view (the Home composer, the
/// omnibar). A sample that has no terminal echo to wait for (``closeAtCommit()``) is written at that
/// commit; one whose key never reached a terminal is written there unfinished.
///
/// Key-press flows (scripts/cmux-next/trace.py) start and stop at run time (``startFlows()``,
/// ``stopFlows()``), as Chromium turns trace categories on in a running browser
/// (base/trace_event/trace_log.h, `TraceLog::SetEnabled`). `CMUX_NEXT_TRACE_FLOWS=<dir>` is only the
/// launch default (``startFlows(launchEnvironment:)`` at the composition root; the daemon gets it as
/// `CMUX_TRACE_FLOWS`). While flows are on, every hop a sample records, plus ``keyReachedTerminal(_:)``
/// and the commit of the frame that shows the echo, is a `key.flow` signpost event
/// (``Signposter/flowHop(_:flow:ageMicroseconds:)``), and the daemon's `send` request carries
/// ``openFlow``, so the daemon, the terminal host and the holder mark the same press on the same clock.
/// No CSV is written without `CMUX_NEXT_TYPING_PROBE`.
public final class TypingLatencyProbe: Sendable {
    public static let shared = TypingLatencyProbe(path: ProcessInfo.processInfo.environment["CMUX_NEXT_TYPING_PROBE"])

    /// The launch default of ``startFlows()`` (``startFlows(launchEnvironment:)``).
    public static let flowsEnvironmentKey = "CMUX_NEXT_TRACE_FLOWS"

    /// Presses tracked at once; a newer press past this closes the oldest unfinished.
    public static let openCapacity = 16

    public static var isEnabled: Bool { shared.isRecording }

    public enum Mark: Int, CaseIterable, Sendable {
        case dispatchStart, dispatchEnd, ioWrite, socketSubmit, outputDecoded, outputReceived, outputParsed, contents, commit

        /// The `key.flow` hop this mark records.
        var hop: KeyFlowHop {
            switch self {
            case .dispatchStart: .appKeyDispatch
            case .dispatchEnd: .appKeyDispatched
            case .ioWrite: .appIOWrite
            case .socketSubmit: .appSend
            case .outputDecoded: .appOutputDecoded
            case .outputReceived: .appOutputReceived
            case .outputParsed: .appOutputParsed
            case .contents: .appFrameContents
            case .commit: .appKeyCommit
            }
        }

        var columnName: String {
            switch self {
            case .dispatchStart: "dispatch_start_ms"
            case .dispatchEnd: "dispatch_end_ms"
            case .ioWrite: "io_write_ms"
            case .socketSubmit: "socket_submit_ms"
            case .outputDecoded: "output_decoded_ms"
            case .outputReceived: "output_received_ms"
            case .outputParsed: "output_parsed_ms"
            case .contents: "contents_ms"
            case .commit: "commit_ms"
            }
        }

        /// The hop that must have run first, so output from an earlier key
        /// is not taken for this key's echo.
        var after: Mark? {
            switch self {
            case .dispatchStart, .dispatchEnd, .ioWrite: nil
            case .socketSubmit: .ioWrite
            case .outputDecoded: .socketSubmit
            case .outputReceived: .outputDecoded
            case .outputParsed: .outputReceived
            case .contents: .outputParsed
            case .commit: .dispatchEnd
            }
        }

        /// Runs inside the key's own dispatch, so it belongs to the newest press.
        var isDispatchHop: Bool {
            switch self {
            case .dispatchStart, .dispatchEnd, .ioWrite, .socketSubmit: true
            case .outputDecoded, .outputReceived, .outputParsed, .contents, .commit: false
            }
        }
    }

    private struct Sample {
        var index: Int
        /// The key press's flow id: this process's pid in the high 32 bits, the sample index below.
        var flow: UInt64
        var event: UInt64
        var marks = [UInt64?](repeating: nil, count: Mark.allCases.count)
        var ioWriteOnMain = false
        /// Written at ``Mark/commit`` instead of ``Mark/contents`` (``closeAtCommit()``).
        var closesAtCommit = false
        /// The key router handed the press to a terminal (``keyReachedTerminal(_:)``).
        var reachedTerminal = false
    }

    /// A hop recorded under the lock, emitted after it.
    private struct Recorded {
        var hop: KeyFlowHop
        var flow: UInt64
        var ageMicroseconds: Int64
        /// The sample this mark finished, to write as a row.
        var finished: Sample?
        /// The finished row is complete: its echo's frame, or the commit it was to close at.
        var complete = true
    }

    private struct State {
        var next = 0
        /// Open presses, oldest first; at most ``openCapacity``.
        var open: [Sample] = []
        /// The flows whose echo frame was handed to their layer (``Mark/contents``) and whose Core
        /// Animation commit (the next run-loop end) is still to be marked `app.frame.commit`.
        var echoCommits: [UInt64] = []

        /// Records `mark` at `now` on `open[index]` the first time it runs and after its ``Mark/after``.
        mutating func record(_ mark: Mark, at index: Int, now: UInt64, onMain: Bool) -> Recorded? {
            var sample = open[index]
            guard sample.marks[mark.rawValue] == nil else { return nil }
            if let after = mark.after, sample.marks[after.rawValue] == nil { return nil }
            sample.marks[mark.rawValue] = now
            if mark == .ioWrite { sample.ioWriteOnMain = onMain }
            var recorded = Recorded(hop: mark.hop, flow: sample.flow,
                                    ageMicroseconds: Int64(bitPattern: now &- sample.event) / 1_000)
            // A press that never reached a terminal has no echo to wait for: its commit ends it.
            if mark == .contents || (mark == .commit && (sample.closesAtCommit || !sample.reachedTerminal)) {
                open.remove(at: index)
                if mark == .contents { echoCommits.append(sample.flow) }
                recorded.finished = sample
                recorded.complete = mark == .contents || sample.closesAtCommit
            } else {
                open[index] = sample
            }
            return recorded
        }
    }

    private let output: FileHandle?
    /// Whether a CSV is written (`CMUX_NEXT_TYPING_PROBE`).
    private let writesCSV: Bool
    /// Key flows are on (``startFlows()``).
    private let flowsOn = Atomic<Bool>(false)
    /// The commit observer is on the main run loop (added once, at the first recording).
    private let observing = Atomic<Bool>(false)
    private let signposter = Signposter(category: .key)
    /// Every `key.flow` hop emitted, before its signpost (tests).
    private let hopRecorder: (@Sendable (_ hop: String, _ flow: UInt64) -> Void)?
    private let state = Mutex(State())
    private let writes = DispatchQueue(label: "com.cmuxterm.next.typing-probe", qos: .utility)

    /// - Parameters:
    ///   - path: The CSV to write, or nil for none.
    ///   - hopRecorder: Hears every `key.flow` hop emitted while flows are on (tests).
    init(path: String?, hopRecorder: (@Sendable (_ hop: String, _ flow: UInt64) -> Void)? = nil) {
        self.hopRecorder = hopRecorder
        if let path, !path.isEmpty, FileManager.default.createFile(atPath: path, contents: nil),
           let handle = FileHandle(forWritingAtPath: path) {
            output = handle
            let header = (["index", "complete", "io_write_on_main"] + Mark.allCases.map(\.columnName)).joined(separator: ",") + "\n"
            handle.write(Data(header.utf8))
        } else {
            output = nil
        }
        writesCSV = output != nil
        if writesCSV { observeCommits() }
    }

    /// Whether the probe records: a CSV is written or key flows are on. One relaxed load while neither.
    public var isRecording: Bool { writesCSV || flowsOn.load(ordering: .relaxed) }

    /// Whether key flows are on.
    public var flowsStarted: Bool { flowsOn.load(ordering: .relaxed) }

    /// Starts key flows: each later key-down gets a flow id, and its hops become `key.flow` events.
    public func startFlows() {
        flowsOn.store(true, ordering: .relaxed)
        observeCommits()
    }

    /// Starts key flows when the app was launched with ``flowsEnvironmentKey`` set.
    public func startFlows(launchEnvironment environment: [String: String]) {
        guard !(environment[Self.flowsEnvironmentKey] ?? "").isEmpty else { return }
        startFlows()
    }

    /// Stops key flows. Without a CSV the open presses are dropped unwritten.
    public func stopFlows() {
        flowsOn.store(false, ordering: .relaxed)
        guard !writesCSV else { return }
        state.withLock { state in
            state.open.removeAll()
            state.echoCommits.removeAll()
        }
    }

    /// The commit mark: the end of each main run-loop turn, after Core Animation's commit observer
    /// (order 2000000). A run-loop observer has no async equivalent; it is added at the first recording
    /// and does nothing while the probe is off.
    private func observeCommits() {
        guard observing.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                          true, 2_000_100) { [weak self] _, _ in
            guard let self, isRecording else { return }
            mark(.commit)
            echoCommitted()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// The flow id of the press being dispatched, for the daemon's `send` request: the newest press
    /// whose input has not gone out yet. Nil while flows are off or no such press is open.
    public var openFlow: UInt64? {
        guard flowsStarted else { return nil }
        return state.withLock { state -> UInt64? in
            guard let newest = state.open.last, newest.marks[Mark.socketSubmit.rawValue] == nil else { return nil }
            return newest.flow
        }
    }

    /// The key router handed the newest press to the terminal whose presses `surface` tracks: records
    /// its `app.key.terminal` hop (no CSV column has it) and opens it on `surface`, so that surface's
    /// output and frame hops mark it. Nothing while the probe is off or no press is open.
    public func keyReachedTerminal(_ surface: SurfaceFlows) {
        guard isRecording, let flow = state.withLock({ state -> UInt64? in
            guard !state.open.isEmpty else { return nil }
            state.open[state.open.count - 1].reachedTerminal = true
            return state.open[state.open.count - 1].flow
        }) else { return }
        surface.open(flow)
        if flowsStarted { emitHop(.appKeyTerminal, flow: flow) }
    }

    /// Marks `app.frame.commit` for each flow whose echo frame went to its layer: the run-loop end that
    /// follows ``Mark/contents`` is the Core Animation commit that carries it to the screen.
    private func echoCommitted() {
        let flows = state.withLock { state -> [UInt64] in
            defer { state.echoCommits.removeAll(keepingCapacity: true) }
            return state.echoCommits
        }
        guard flowsStarted else { return }
        for flow in flows { emitHop(.appFrameCommit, flow: flow) }
    }

    /// Opens a sample for a key-down whose `NSEvent.timestamp` is `eventTimestamp`.
    public func keyDown(eventTimestamp: Double) {
        guard isRecording else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let event = eventTimestamp > 0 ? UInt64(eventTimestamp * 1_000_000_000) : now
        let flowBase = UInt64(UInt32(truncatingIfNeeded: getpid())) << 32
        let (unfinished, flow) = state.withLock { state -> (Sample?, UInt64) in
            let oldest = state.open.count >= Self.openCapacity ? state.open.removeFirst() : nil
            var sample = Sample(index: state.next, flow: flowBase | UInt64(UInt32(truncatingIfNeeded: state.next)), event: event)
            sample.marks[Mark.dispatchStart.rawValue] = now
            state.next += 1
            state.open.append(sample)
            return (oldest, sample.flow)
        }
        if let unfinished { emit(unfinished, complete: false) }
        if flowsStarted {
            emitHop(Mark.dispatchStart.hop, flow: flow, ageMicroseconds: Int64(bitPattern: now &- event) / 1_000)
        }
    }

    /// Records `mark` the first time it runs for a press, after the hop it follows (``Mark/after``). A
    /// dispatch hop goes to the newest press, a commit to every press, and an output hop (named by no
    /// flow or surface) to the oldest press that takes it.
    public func mark(_ mark: Mark) {
        guard isRecording else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let onMain = mark == .ioWrite && Thread.isMainThread
        let recorded = state.withLock { state -> [Recorded] in
            if mark.isDispatchHop {
                guard !state.open.isEmpty else { return [] }
                return state.record(mark, at: state.open.count - 1, now: now, onMain: onMain).map { [$0] } ?? []
            }
            if mark == .commit {
                var recorded: [Recorded] = []
                // Newest first: a press the commit closes leaves the indices below it in place.
                for index in state.open.indices.reversed() {
                    if let one = state.record(mark, at: index, now: now, onMain: onMain) { recorded.append(one) }
                }
                return recorded
            }
            for index in state.open.indices {
                if let one = state.record(mark, at: index, now: now, onMain: onMain) { return [one] }
            }
            return []
        }
        finish(recorded)
    }

    /// Records `mark` for the press `flow` names (the daemon's `output` event carries it), or as
    /// ``mark(_:)`` when the event names none (a daemon without exact flows).
    public func mark(_ mark: Mark, flow: UInt64?) {
        guard isRecording else { return }
        guard let flow else { return self.mark(mark) }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let onMain = mark == .ioWrite && Thread.isMainThread
        let recorded = state.withLock { state -> Recorded? in
            guard let index = state.open.firstIndex(where: { $0.flow == flow }) else { return nil }
            return state.record(mark, at: index, now: now, onMain: onMain)
        }
        finish(recorded.map { [$0] } ?? [])
    }

    /// Records `mark` for every press open on `surface` (its output lane's received and parsed hops, its
    /// layer's contents): each takes it once its echo's earlier hops ran. A press whose frame landed
    /// leaves the surface.
    public func mark(_ mark: Mark, surface: SurfaceFlows) {
        guard isRecording else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let recorded = state.withLock { state -> [Recorded] in
            var recorded: [Recorded] = []
            surface.forEachOpen { flow in
                guard let index = state.open.firstIndex(where: { $0.flow == flow }) else { return }
                if let one = state.record(mark, at: index, now: now, onMain: false) { recorded.append(one) }
            }
            return recorded
        }
        for one in recorded where one.finished != nil { surface.close(one.flow) }
        finish(recorded)
    }

    /// The open sample is written at its commit mark (now, when that already ran): the key
    /// went to a text view, so no terminal echo follows (`debug.key` with `probe: "commit"`).
    public func closeAtCommit() {
        guard isRecording else { return }
        let finished = state.withLock { state -> Sample? in
            guard var sample = state.open.last else { return nil }
            if sample.marks[Mark.commit.rawValue] != nil {
                state.open.removeLast()
                return sample
            }
            sample.closesAtCommit = true
            state.open[state.open.count - 1] = sample
            return nil
        }
        if let finished { emit(finished, complete: true) }
    }

    /// Waits for every row emitted so far to reach the file (tests).
    func flush() {
        writes.sync {}
    }

    /// Emits each recorded hop (while flows are on) and writes each finished sample.
    private func finish(_ recorded: [Recorded]) {
        let flows = flowsStarted
        for one in recorded {
            if flows { emitHop(one.hop, flow: one.flow, ageMicroseconds: one.ageMicroseconds) }
            if let finished = one.finished { emit(finished, complete: one.complete) }
        }
    }

    private func emitHop(_ hop: KeyFlowHop, flow: UInt64, ageMicroseconds: Int64 = -1) {
        hopRecorder?(hop.rawValue, flow)
        signposter.flowHop(hop, flow: flow, ageMicroseconds: ageMicroseconds)
    }

    private func emit(_ sample: Sample, complete: Bool) {
        guard let output else { return }
        writes.async {
            let millis = sample.marks.map { mark in
                mark.map { String(format: "%.3f", Double(Int64(bitPattern: $0 &- sample.event)) / 1_000_000) } ?? ""
            }
            let row = (["\(sample.index)", complete ? "1" : "0", sample.ioWriteOnMain ? "1" : "0"] + millis).joined(separator: ",") + "\n"
            output.write(Data(row.utf8))
        }
    }
}
