import Foundation
import CmuxNextCompat
import CmuxNextSignposts

/// Opt-in keystroke-to-frame timeline for one terminal key at a time
/// (`CMUX_NEXT_TYPING_PROBE=<csv path>`). Off by default: every hop then
/// costs one load of ``isEnabled``.
///
/// A sample opens at a key-down and records the first time each later hop
/// runs: AppKit dispatch, Ghostty's write callback, the attach socket
/// submit, the echo's decode on the attach reader, the session taking it for its
/// output lane (`output_received_ms`: off the main actor since G4, so rows before 04237873b23
/// named this column `output_main_ms` and do not compare),
/// its parse on the output lane, the first `layer.contents` set after
/// that parse, and the end of that run-loop turn (`contents_commit_ms`: the
/// Core Animation commit that carries the echo to the screen). The row is
/// appended at that commit. Drive it with keys paced wider than one round trip;
/// a key that arrives while a sample is open closes the old one unfinished.
///
/// A key typed into a terminal (``TypingProbeTargeting``) samples only that terminal: marks scoped to
/// another terminal (``Scope``: its daemon surface below the view, its view above it) are ignored, so a
/// busy terminal's output and frames never pass for the typed one's echo. Unscoped marks (dispatch,
/// commit) count as before.
/// Times are milliseconds after the event's own timestamp (seconds since
/// boot, the same clock as `CLOCK_UPTIME_RAW`).
///
/// `commit_ms` is the end of the first main run-loop turn after dispatch,
/// past Core Animation's commit observer: the frame that carries what the
/// key changed in an AppKit text view (the Home composer, the omnibar).
/// A sample that has no terminal echo to wait for (``closeAtCommit()``)
/// is written at that commit.
///
/// Key-press flows (`CMUX_TRACE_FLOWS=<dir>`, scripts/cmux-next/trace.py):
/// each sample also gets a flow id, and every hop it records, plus the
/// extra ``hop(_:)`` points and the commit of the frame that shows the echo,
/// is a `key.flow` signpost event (``Signposter/flowHop(_:flow:ageMicroseconds:)``).
/// The daemon's `send` request carries ``openFlow``, so the daemon, the
/// terminal host and the holder mark the same press on the same clock. The
/// variable alone turns sampling on (no CSV is written without
/// `CMUX_NEXT_TYPING_PROBE`).
public final class TypingLatencyProbe: Sendable {
    public static let shared = TypingLatencyProbe(path: ProcessInfo.processInfo.environment["CMUX_NEXT_TYPING_PROBE"],
                                                  flows: !(ProcessInfo.processInfo.environment["CMUX_TRACE_FLOWS"] ?? "").isEmpty)

    public static var isEnabled: Bool { shared.output != nil || shared.flows != nil }

    public enum Mark: Int, CaseIterable, Sendable {
        case dispatchStart, dispatchEnd, ioWrite, socketSubmit, outputDecoded, outputReceived, outputParsed, contents, commit
        /// The end of the run-loop turn that set the typed terminal's contents: the Core Animation commit
        /// that shows the echo (``contents`` is the `setContents:` call before it).
        case contentsCommit

        /// The `key.flow` hop this mark records.
        var hopName: String {
            switch self {
            case .dispatchStart: "app.key.dispatch"
            case .dispatchEnd: "app.key.dispatched"
            case .ioWrite: "app.io_write"
            case .socketSubmit: "app.send"
            case .outputDecoded: "app.output.decoded"
            case .outputReceived: "app.output.received"
            case .outputParsed: "app.output.parsed"
            case .contents: "app.frame.contents"
            case .commit: "app.key.commit"
            case .contentsCommit: "app.frame.commit"
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
            case .contentsCommit: "contents_commit_ms"
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
            case .contentsCommit: .contents
            }
        }
    }

    /// The terminal a sampled key went to: output and frames of any other terminal are not its echo. `surface` is
    /// its daemon surface (the input and output marks below the view know only it; nil: unknown, so those marks are
    /// not filtered); `view` is the terminal view's identity (`ObjectIdentifier(view).hashValue`: its output lane,
    /// IO bridge and layer know only that).
    public struct Target: Sendable, Hashable {
        public var surface: UInt64?
        public var view: Int

        /// - Parameters:
        ///   - surface: The terminal's daemon surface, nil when the view has none (a local terminal).
        ///   - view: The terminal view's identity.
        public init(surface: UInt64?, view: Int) {
            self.surface = surface
            self.view = view
        }
    }

    /// Where a mark comes from, when it comes from one terminal: a sample with a ``Target`` takes it only from that
    /// terminal.
    public enum Scope: Sendable, Hashable {
        /// A daemon surface (the attach socket's marks).
        case surface(UInt64)
        /// A terminal view (its output lane, IO bridge and layer).
        case view(Int)
    }

    private struct Sample {
        var index: Int
        /// The key press's flow id: this process's pid in the high 32 bits, the sample index below.
        var flow: UInt64
        var event: UInt64
        /// The terminal the key went to; nil: the first output and frame of any terminal count.
        var target: Target?
        var marks = [UInt64?](repeating: nil, count: Mark.allCases.count)
        var ioWriteOnMain = false
        /// Written at ``Mark/commit`` instead of ``Mark/contentsCommit`` (``closeAtCommit()``).
        var closesAtCommit = false
    }

    private struct State {
        var next = 0
        var open: Sample?
        /// The terminal view each probed layer belongs to (``register(layer:view:)``), so its `setContents:`,
        /// which may run off the main thread, is scoped to that view.
        var layerViews: [ObjectIdentifier: Int] = [:]
    }

    private let output: FileHandle?
    /// The `key.flow` signposter while `CMUX_TRACE_FLOWS` is set, else nil.
    private let flows: Signposter?
    private let state = Mutex(State())
    private let writes = DispatchQueue(label: "com.cmuxterm.next.typing-probe", qos: .utility)

    init(path: String?, flows: Bool = false) {
        self.flows = flows ? Signposter(category: .key) : nil
        if let path, !path.isEmpty, FileManager.default.createFile(atPath: path, contents: nil),
           let handle = FileHandle(forWritingAtPath: path) {
            output = handle
            let header = (["index", "complete", "io_write_on_main"] + Mark.allCases.map(\.columnName)).joined(separator: ",") + "\n"
            handle.write(Data(header.utf8))
        } else {
            output = nil
        }
        guard output != nil || flows else { return }
        // The commit mark: the end of each main run-loop turn, after Core Animation's commit observer
        // (order 2000000). A run-loop observer has no async equivalent; it exists only while the probe is on.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                          true, 2_000_100) { [weak self] _, _ in
            self?.mark(.commit)
            // After ``Mark/contents``: this turn's Core Animation commit carries the echo (`app.frame.commit`).
            self?.mark(.contentsCommit)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// The flow id of the open key press, for the daemon's `send` request; nil while flows are off
    /// or no press is open.
    public var openFlow: UInt64? {
        guard flows != nil else { return nil }
        return state.withLock { $0.open?.flow }
    }

    /// Records a `key.flow` hop of the open press that no CSV column has (`app.key.terminal`: the key
    /// router handed the key to a terminal). Nothing while flows are off or no press is open.
    public func hop(_ name: String) {
        guard let flows, let flow = state.withLock({ $0.open?.flow }) else { return }
        flows.flowHop(name, flow: flow)
    }

    /// Scopes `layer`'s `setContents:` to the terminal view `view` (``markContents(layer:)``).
    public func register(layer: ObjectIdentifier, view: Int) {
        guard output != nil || flows != nil else { return }
        state.withLock { $0.layerViews[layer] = view }
    }

    /// ``Mark/contents`` from a probed layer, scoped to the view it was registered for (any thread).
    public func markContents(layer: ObjectIdentifier) {
        guard output != nil || flows != nil else { return }
        let view = state.withLock { $0.layerViews[layer] }
        mark(.contents, scope: view.map(Scope.view))
    }

    /// Opens a sample for a key-down whose `NSEvent.timestamp` is `eventTimestamp`, typed into `target`
    /// (nil: not a terminal, or unknown; the first output and frame of any terminal count, as before).
    public func keyDown(eventTimestamp: Double, target: Target? = nil) {
        guard output != nil || flows != nil else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let event = eventTimestamp > 0 ? UInt64(eventTimestamp * 1_000_000_000) : now
        let flowBase = UInt64(UInt32(truncatingIfNeeded: getpid())) << 32
        let (unfinished, flow) = state.withLock { state -> (Sample?, UInt64) in
            let previous = state.open
            var sample = Sample(index: state.next, flow: flowBase | UInt64(UInt32(truncatingIfNeeded: state.next)), event: event,
                                target: target)
            sample.marks[Mark.dispatchStart.rawValue] = now
            state.next += 1
            state.open = sample
            return (previous, sample.flow)
        }
        if let unfinished { emit(unfinished, complete: false) }
        flows?.flowHop(Mark.dispatchStart.hopName, flow: flow, ageMicroseconds: Int64(bitPattern: now &- event) / 1_000)
    }

    /// Records `mark` for the open sample the first time it runs. A mark before the hop it follows (``Mark/after``) is
    /// ignored, and so is a mark scoped to another terminal than the sample's target (`scope`; nil: unscoped).
    public func mark(_ mark: Mark, scope: Scope? = nil) {
        guard output != nil || flows != nil else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let onMain = mark == .ioWrite && Thread.isMainThread
        let (finished, recorded) = state.withLock { state -> (Sample?, Sample?) in
            guard var sample = state.open, sample.marks[mark.rawValue] == nil else { return (nil, nil) }
            if let target = sample.target, let scope {
                switch scope {
                case .surface(let surface): if let own = target.surface, own != surface { return (nil, nil) }
                case .view(let view): if view != target.view { return (nil, nil) }
                }
            }
            if let after = mark.after, sample.marks[after.rawValue] == nil { return (nil, nil) }
            sample.marks[mark.rawValue] = now
            if mark == .ioWrite { sample.ioWriteOnMain = onMain }
            if mark == .contentsCommit || (mark == .commit && sample.closesAtCommit) {
                state.open = nil
                return (sample, sample)
            }
            state.open = sample
            return (nil, sample)
        }
        if let recorded, let flows {
            flows.flowHop(mark.hopName, flow: recorded.flow, ageMicroseconds: Int64(bitPattern: now &- recorded.event) / 1_000)
        }
        if let finished { emit(finished, complete: true) }
    }

    /// The open sample is written at its commit mark (now, when that already ran): the key
    /// went to a text view, so no terminal echo follows (`debug.key` with `probe: "commit"`).
    public func closeAtCommit() {
        guard output != nil || flows != nil else { return }
        let finished = state.withLock { state -> Sample? in
            guard var sample = state.open else { return nil }
            if sample.marks[Mark.commit.rawValue] != nil {
                state.open = nil
                return sample
            }
            sample.closesAtCommit = true
            state.open = sample
            return nil
        }
        if let finished { emit(finished, complete: true) }
    }

    /// Waits for every row emitted so far to reach the file (tests).
    func flush() {
        writes.sync {}
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
