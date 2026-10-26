import Foundation
import CmuxNextCompat
import CmuxNextSignposts
import CmuxNextTrace

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
/// Which press a hop belongs to:
/// - Dispatch hops run inside the key's own dispatch on the main thread: the newest press.
/// - Ghostty writes one surface's keys in order on its IO thread, and the session sends them in that
///   order, so a write goes to its surface's oldest unwritten press (``inputWritten(on:)``) and a send to
///   the oldest written, unsent press (``openFlow``), never to whichever key was pressed last.
/// - The send carries that press's flow, and the daemon's `output` event names the press it echoes
///   (p09-observability-018), so the decode marks that press (``outputDecoded(flow:)``) and the attach
///   stream carries the flow with the chunk to the session and the lane (``mark(_:flow:)``). The surface's
///   frame then marks the presses on it whose echo was parsed (``mark(_:surface:)``).
/// - A daemon without exact flows names no press: the newest press sent takes the decode and older
///   undecoded ones close unfinished, and the surface's output chunks mark it.
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
/// (``Signposter/flowHop(_:flow:ageMicroseconds:)``), so the daemon, the terminal host and the holder
/// mark the same press on the same clock. No CSV is written without `CMUX_NEXT_TYPING_PROBE`.
///
/// Nothing is sampled while the trace runtime's keystroke-timing gate is closed (secure keyboard entry,
/// ``TraceRuntime/isKeyTimingSuppressed``, p09-observability-128): a key-down then drops every open press
/// unwritten and opens none, no hop is recorded and ``openFlow`` is nil, so the daemon, the terminal host and
/// the holder write no `key.echo` hop for a key typed into a password prompt.
public final class TypingLatencyProbe: Sendable {
    public static let shared = TypingLatencyProbe(path: ProcessInfo.processInfo.environment["CMUX_NEXT_TYPING_PROBE"])

    /// The launch default of ``startFlows()`` (``startFlows(launchEnvironment:)``).
    public static let flowsEnvironmentKey = "CMUX_NEXT_TRACE_FLOWS"

    /// Presses tracked at once, on every surface together; a newer press past this closes the oldest
    /// unfinished.
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
    }

    struct Sample {
        var index: Int
        /// The key press's flow id: this process's pid in the high 32 bits, the sample index below.
        var flow: UInt64
        var event: UInt64
        var marks = [UInt64?](repeating: nil, count: Mark.allCases.count)
        var ioWriteOnMain = false
        /// Written at ``Mark/commit`` instead of ``Mark/contents`` (``closeAtCommit()``).
        var closesAtCommit = false
        /// The terminal the key router handed the press to (``keyReachedTerminal(_:)``); nil while none.
        var surface: SurfaceKey?
        /// Ghostty took the press (``terminalTookKey()``), so its bytes are to be written.
        var tookByTerminal = false
        /// The daemon's echo named this press (``outputDecoded(flow:)``): its later output hops come with
        /// that chunk (``mark(_:flow:)``), never from the surface's other output.
        var exactEcho = false

        func has(_ mark: Mark) -> Bool { marks[mark.rawValue] != nil }

        /// Ghostty may still write this press's bytes on `surface`: the key went there, and its dispatch
        /// has not ended without Ghostty taking it. The write runs on the IO thread and may come before
        /// the dispatch ends, so a press still in dispatch counts.
        func awaitsWrite(on surface: SurfaceKey) -> Bool {
            self.surface == surface && !has(.ioWrite) && (tookByTerminal || !has(.dispatchEnd))
        }
    }

    /// A hop recorded under the lock, emitted after it.
    struct Recorded {
        var hop: KeyFlowHop
        var flow: UInt64
        var ageMicroseconds: Int64
        /// The sample this mark finished, to write as a row.
        var finished: Sample?
        /// The finished row is complete: its echo's frame, or the commit it was to close at.
        var complete = true
    }

    struct State {
        var next = 0
        /// Open presses, oldest first; at most ``openCapacity``.
        var open: [Sample] = []
        /// The flows whose echo frame was handed to their layer (``Mark/contents``) and whose Core
        /// Animation commit (the next run-loop end) is still to be marked `app.frame.commit`.
        var echoCommits: [UInt64] = []
        /// An echo named its press (``outputDecoded(flow:)``): the daemon stamps exact flows, so an
        /// output that names none is not a key's echo.
        var exactEchoes = false

        /// The press being dispatched on the main thread.
        var newest: Int? { open.isEmpty ? nil : open.count - 1 }

        /// Records `mark` at `now` on `open[index]` the first time it runs and after its ``Mark/after``.
        mutating func record(_ mark: Mark, at index: Int, now: UInt64, onMain: Bool) -> Recorded? {
            var sample = open[index]
            guard !sample.has(mark) else { return nil }
            if let after = mark.after, !sample.has(after) { return nil }
            sample.marks[mark.rawValue] = now
            if mark == .ioWrite { sample.ioWriteOnMain = onMain }
            var recorded = Recorded(hop: mark.hop, flow: sample.flow,
                                    ageMicroseconds: Int64(bitPattern: now &- sample.event) / 1_000)
            // A press that never reached a terminal has no echo to wait for: its commit ends it.
            if mark == .contents || (mark == .commit && (sample.closesAtCommit || sample.surface == nil)) {
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
    /// The last ``SurfaceKey`` handed out (``makeSurfaceKey()``).
    let surfaceIDs = Atomic<UInt64>(0)
    /// The `key.flow` signposter, gated by ``trace``'s keystroke-timing gate.
    private let signposter: Signposter
    /// The runtime whose keystroke-timing gate stops sampling (the app's: ``TraceRuntime/shared``).
    private let trace: TraceRuntime
    /// Every `key.flow` hop emitted, before its signpost (tests).
    private let hopRecorder: (@Sendable (_ hop: String, _ flow: UInt64) -> Void)?
    let state = Mutex(State())
    private let writes = DispatchQueue(label: "com.cmuxterm.next.typing-probe", qos: .utility)

    /// - Parameters:
    ///   - path: The CSV to write, or nil for none.
    ///   - trace: The runtime whose keystroke-timing gate stops sampling.
    ///   - hopRecorder: Hears every `key.flow` hop emitted while flows are on (tests).
    init(path: String?, trace: TraceRuntime = .shared, hopRecorder: (@Sendable (_ hop: String, _ flow: UInt64) -> Void)? = nil) {
        self.trace = trace
        signposter = Signposter(category: .key, trace: trace)
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

    /// Whether a hop is recorded now: the probe records and the keystroke-timing gate is open.
    var isSampling: Bool { isRecording && !trace.isKeyTimingSuppressed }

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

    /// Opens a sample for a key-down whose `NSEvent.timestamp` is `eventTimestamp`. While the keystroke-timing
    /// gate is closed it only drops every open press, unwritten, and opens none.
    public func keyDown(eventTimestamp: Double) {
        guard isRecording else { return }
        guard !trace.isKeyTimingSuppressed else {
            state.withLock { state in
                state.open.removeAll()
                state.echoCommits.removeAll()
            }
            return
        }
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

    /// Records a dispatch hop (``Mark/dispatchStart``, ``Mark/dispatchEnd``) for the newest press, whose
    /// dispatch it runs in, or ``Mark/commit`` for every press. The other marks belong to a press that
    /// ``inputWritten(on:)``, ``mark(_:flow:)``, ``outputDecoded(flow:)`` or ``mark(_:surface:)`` names,
    /// and do nothing here.
    public func mark(_ mark: Mark) {
        guard isSampling else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let recorded = state.withLock { state -> [Recorded] in
            switch mark {
            case .dispatchStart, .dispatchEnd:
                guard let newest = state.newest else { return [] }
                return state.record(mark, at: newest, now: now, onMain: false).map { [$0] } ?? []
            case .commit:
                var recorded: [Recorded] = []
                // Newest first: a press the commit closes leaves the indices below it in place.
                for index in state.open.indices.reversed() {
                    if let one = state.record(mark, at: index, now: now, onMain: false) { recorded.append(one) }
                }
                return recorded
            case .ioWrite, .socketSubmit, .outputDecoded, .outputReceived, .outputParsed, .contents:
                return []
            }
        }
        finish(recorded)
    }

    /// The open sample is written at its commit mark (now, when that already ran): the key
    /// went to a text view, so no terminal echo follows (`debug.key` with `probe: "commit"`).
    public func closeAtCommit() {
        guard isSampling else { return }
        let finished = state.withLock { state -> Sample? in
            guard var sample = state.open.last else { return nil }
            if sample.has(.commit) {
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
    func finish(_ recorded: [Recorded]) {
        let flows = flowsStarted
        for one in recorded {
            if flows { emitHop(one.hop, flow: one.flow, ageMicroseconds: one.ageMicroseconds) }
            if let finished = one.finished { emit(finished, complete: one.complete) }
        }
    }

    func emitHop(_ hop: KeyFlowHop, flow: UInt64, ageMicroseconds: Int64 = -1) {
        hopRecorder?(hop.rawValue, flow)
        signposter.flowHop(hop, flow: flow, ageMicroseconds: ageMicroseconds)
    }

    func emit(_ sample: Sample, complete: Bool) {
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
