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
/// its parse on the output lane, and the first `layer.contents` set after
/// that parse (the frame Core Animation commits). The row is appended when
/// that frame lands. Drive it with keys paced wider than one round trip;
/// a key that arrives while a sample is open closes the old one unfinished.
/// Times are milliseconds after the event's own timestamp (seconds since
/// boot, the same clock as `CLOCK_UPTIME_RAW`); the last column,
/// `event_uptime_ns`, is that timestamp itself, so a row joins a HID post
/// time, a `debug.hangs` stall or a screen recording's frame times.
///
/// One press at a time, tied to its terminal: the echo hops take a `source`
/// (``mark(_:source:next:)``), and a hop counts only from the object the
/// previous hop named. The attachment that sent the press (``Mark/socketSubmit``)
/// names who may decode and receive its echo, the receiving session names its
/// output lane, and the lane names the layer whose frame shows the echo. Output
/// of a busy neighbor terminal therefore never closes the press. The flow id
/// goes on the `send` of the attachment that first asks (``openFlow(for:)``,
/// read on Ghostty's IO thread); a second terminal's input while a press is open
/// carries it only if no attachment has claimed the press yet.
///
/// `commit_ms` is the end of the first main run-loop turn after dispatch,
/// past Core Animation's commit observer: the frame that carries what the
/// key changed in an AppKit text view (the Home composer, the omnibar).
/// A sample that has no terminal echo to wait for (``closeAtCommit()``)
/// is written at that commit.
///
/// Key-press flows (`CMUX_NEXT_TRACE_FLOWS=<dir>` on the app, passed to the daemon as
/// `CMUX_TRACE_FLOWS`; scripts/cmux-next/trace.py):
/// each sample also gets a flow id, and every hop it records, plus the
/// extra ``hop(_:)`` points and the commit of the frame that shows the echo,
/// is a `key.flow` signpost event (``Signposter/flowHop(_:flow:ageMicroseconds:)``).
/// The daemon's `send` request carries ``openFlow(for:)``, so the daemon, the
/// terminal host and the holder mark the same press on the same clock. The
/// variable alone turns sampling on (no CSV is written without
/// `CMUX_NEXT_TYPING_PROBE`).
public final class TypingLatencyProbe: Sendable {
    public static let shared = TypingLatencyProbe(path: ProcessInfo.processInfo.environment["CMUX_NEXT_TYPING_PROBE"],
                                                  flows: !(ProcessInfo.processInfo.environment["CMUX_NEXT_TRACE_FLOWS"] ?? "").isEmpty)

    public static var isEnabled: Bool { shared.output != nil || shared.flows != nil }

    /// What an echo hop runs for (``mark(_:source:next:)``): a daemon terminal by its surface id on the
    /// network side (the attachment that sent the key and the session's IO both know it), an object on
    /// the render side (the output lane, the layer).
    public enum Source: Hashable, Sendable {
        /// A daemon terminal's surface id (`SurfaceID.rawValue`), never the unresolved 0.
        case terminal(UInt64)
        /// One object: an output lane, a layer, or an attachment whose surface is not resolved yet.
        case object(ObjectIdentifier)
    }

    public enum Mark: Int, CaseIterable, Sendable {
        case dispatchStart, dispatchEnd, ioWrite, socketSubmit, outputDecoded, outputReceived, outputParsed, contents, commit

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

    private struct Sample {
        var index: Int
        /// The key press's flow id: this process's pid in the high 32 bits, the sample index below.
        var flow: UInt64
        var event: UInt64
        var marks = [UInt64?](repeating: nil, count: Mark.allCases.count)
        var ioWriteOnMain = false
        /// The object each hop must come from, set by the hop before it (``mark(_:source:next:)``);
        /// nil: any source.
        var expected = [Source?](repeating: nil, count: Mark.allCases.count)
        /// Written at ``Mark/commit`` instead of ``Mark/contents`` (``closeAtCommit()``).
        var closesAtCommit = false
    }

    private struct State {
        var next = 0
        var open: Sample?
        /// The flow whose echo frame was handed to its layer (``Mark/contents``) and whose Core
        /// Animation commit (the next run-loop end) is still to be marked `app.frame.commit`.
        var echoCommit: UInt64?
    }

    private let output: FileHandle?
    /// The `key.flow` signposter while `CMUX_NEXT_TRACE_FLOWS` is set, else nil.
    private let flows: Signposter?
    private let state = Mutex(State())
    private let writes = DispatchQueue(label: "com.cmuxterm.next.typing-probe", qos: .utility)

    init(path: String?, flows: Bool = false) {
        self.flows = flows ? Signposter(category: .key) : nil
        if let path, !path.isEmpty, FileManager.default.createFile(atPath: path, contents: nil),
           let handle = FileHandle(forWritingAtPath: path) {
            output = handle
            // `event_uptime_ns` last, so readers that pick columns by name or by position keep working.
            let header = (["index", "complete", "io_write_on_main"] + Mark.allCases.map(\.columnName) + ["event_uptime_ns"])
                .joined(separator: ",") + "\n"
            handle.write(Data(header.utf8))
        } else {
            output = nil
        }
        guard output != nil || flows else { return }
        // The commit mark: the end of each main run-loop turn, after Core Animation's commit observer
        // (order 2000000). A run-loop observer has no async equivalent; it exists only while the probe is on.
        // It only stamps the commit mark: its context says so to the commit-boundary audit.
        let observer = MainRunLoopObserver.afterCommitObserver(activities: [.beforeWaiting, .exit], order: 2_000_100) { [weak self] _ in
            self?.mark(.commit)
            self?.echoCommitted()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// The flow id of the open key press for a `send` of the attachment `source`: nil while flows are
    /// off, no press is open, or another attachment already sent the press.
    public func openFlow(for source: Source) -> UInt64? {
        guard flows != nil else { return nil }
        return state.withLock { state -> UInt64? in
            guard let open = state.open else { return nil }
            let claimed = open.expected[Mark.outputDecoded.rawValue]
            return claimed == nil || claimed == source ? open.flow : nil
        }
    }

    /// Records a `key.flow` hop of the open press that no CSV column has (`app.key.terminal`: the key
    /// router handed the key to a terminal). Nothing while flows are off or no press is open.
    public func hop(_ name: String) {
        guard let flows, let flow = state.withLock({ $0.open?.flow }) else { return }
        flows.flowHop(name, flow: flow)
    }

    /// Marks `app.frame.commit` for the flow whose echo frame went to its layer: the run-loop end that
    /// follows ``Mark/contents`` is the Core Animation commit that carries it to the screen.
    private func echoCommitted() {
        guard let flows, let flow = state.withLock({ state -> UInt64? in
            defer { state.echoCommit = nil }
            return state.echoCommit
        }) else { return }
        flows.flowHop("app.frame.commit", flow: flow)
    }

    /// Opens a sample for a key-down whose `NSEvent.timestamp` is `eventTimestamp`.
    public func keyDown(eventTimestamp: Double) {
        guard output != nil || flows != nil else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let event = eventTimestamp > 0 ? UInt64(eventTimestamp * 1_000_000_000) : now
        let flowBase = UInt64(UInt32(truncatingIfNeeded: getpid())) << 32
        let (unfinished, flow) = state.withLock { state -> (Sample?, UInt64) in
            let previous = state.open
            var sample = Sample(index: state.next, flow: flowBase | UInt64(UInt32(truncatingIfNeeded: state.next)), event: event)
            sample.marks[Mark.dispatchStart.rawValue] = now
            state.next += 1
            state.open = sample
            return (previous, sample.flow)
        }
        if let unfinished { emit(unfinished, complete: false) }
        flows?.flowHop(Mark.dispatchStart.hopName, flow: flow, ageMicroseconds: Int64(bitPattern: now &- event) / 1_000)
    }

    /// Records `mark` for the open sample the first time it runs. A mark
    /// before the hop it follows (``Mark/after``) is ignored, and so is a mark
    /// from another `source` than the one the hop before named.
    ///
    /// - Parameters:
    ///   - source: What this hop runs for: the daemon terminal for ``Mark/socketSubmit``,
    ///     ``Mark/outputDecoded`` and ``Mark/outputReceived``, the output lane for
    ///     ``Mark/outputParsed``, the layer for ``Mark/contents``. Nil for the key hops; a nil
    ///     source never matches a hop that expects one.
    ///   - next: The object the following hop must come from: the session's output lane at
    ///     ``Mark/outputReceived``, the lane's layer at ``Mark/outputParsed``.
    public func mark(_ mark: Mark, source: Source? = nil, next: Source? = nil) {
        guard output != nil || flows != nil else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let onMain = mark == .ioWrite && Thread.isMainThread
        let (finished, recorded) = state.withLock { state -> (Sample?, Sample?) in
            guard var sample = state.open, sample.marks[mark.rawValue] == nil else { return (nil, nil) }
            if let after = mark.after, sample.marks[after.rawValue] == nil { return (nil, nil) }
            if let expected = sample.expected[mark.rawValue], expected != source { return (nil, nil) }
            sample.marks[mark.rawValue] = now
            switch mark {
            case .socketSubmit:
                // The attachment that sent the press decodes and receives its echo.
                sample.expected[Mark.outputDecoded.rawValue] = source
                sample.expected[Mark.outputReceived.rawValue] = source
            case .outputReceived: sample.expected[Mark.outputParsed.rawValue] = next
            case .outputParsed: sample.expected[Mark.contents.rawValue] = next
            default: break
            }
            if mark == .ioWrite { sample.ioWriteOnMain = onMain }
            if mark == .contents || (mark == .commit && sample.closesAtCommit) {
                state.open = nil
                if mark == .contents { state.echoCommit = sample.flow }
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
            let row = (["\(sample.index)", complete ? "1" : "0", sample.ioWriteOnMain ? "1" : "0"] + millis + ["\(sample.event)"])
                .joined(separator: ",") + "\n"
            output.write(Data(row.utf8))
        }
    }
}
