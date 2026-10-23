import Foundation
import CmuxNextCompat

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
/// boot, the same clock as `CLOCK_UPTIME_RAW`).
///
/// `commit_ms` is the end of the first main run-loop turn after dispatch,
/// past Core Animation's commit observer: the frame that carries what the
/// key changed in an AppKit text view (the Home composer, the omnibar).
/// A sample that has no terminal echo to wait for (``closeAtCommit()``)
/// is written at that commit.
public final class TypingLatencyProbe: Sendable {
    public static let shared = TypingLatencyProbe(path: ProcessInfo.processInfo.environment["CMUX_NEXT_TYPING_PROBE"])

    public static var isEnabled: Bool { shared.output != nil }

    public enum Mark: Int, CaseIterable, Sendable {
        case dispatchStart, dispatchEnd, ioWrite, socketSubmit, outputDecoded, outputReceived, outputParsed, contents, commit

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
        var event: UInt64
        var marks = [UInt64?](repeating: nil, count: Mark.allCases.count)
        var ioWriteOnMain = false
        /// Written at ``Mark/commit`` instead of ``Mark/contents`` (``closeAtCommit()``).
        var closesAtCommit = false
    }

    private struct State {
        var next = 0
        var open: Sample?
    }

    private let output: FileHandle?
    private let state = Mutex(State())
    private let writes = DispatchQueue(label: "com.cmuxterm.next.typing-probe", qos: .utility)

    init(path: String?) {
        guard let path, !path.isEmpty,
              FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path)
        else {
            output = nil
            return
        }
        output = handle
        let header = (["index", "complete", "io_write_on_main"] + Mark.allCases.map(\.columnName)).joined(separator: ",") + "\n"
        handle.write(Data(header.utf8))
        // The commit mark: the end of each main run-loop turn, after Core Animation's commit observer
        // (order 2000000). A run-loop observer has no async equivalent; it exists only while the probe is on.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                          true, 2_000_100) { [weak self] _, _ in self?.mark(.commit) }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Opens a sample for a key-down whose `NSEvent.timestamp` is `eventTimestamp`.
    public func keyDown(eventTimestamp: Double) {
        guard output != nil else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let event = eventTimestamp > 0 ? UInt64(eventTimestamp * 1_000_000_000) : now
        let unfinished = state.withLock { state -> Sample? in
            let previous = state.open
            var sample = Sample(index: state.next, event: event)
            sample.marks[Mark.dispatchStart.rawValue] = now
            state.next += 1
            state.open = sample
            return previous
        }
        if let unfinished { emit(unfinished, complete: false) }
    }

    /// Records `mark` for the open sample the first time it runs. A mark
    /// before the hop it follows (``Mark/after``) is ignored. Output hops
    /// are not tied to a surface: type into one terminal while sampling.
    public func mark(_ mark: Mark) {
        guard output != nil else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let onMain = mark == .ioWrite && Thread.isMainThread
        let finished = state.withLock { state -> Sample? in
            guard var sample = state.open, sample.marks[mark.rawValue] == nil else { return nil }
            if let after = mark.after, sample.marks[after.rawValue] == nil { return nil }
            sample.marks[mark.rawValue] = now
            if mark == .ioWrite { sample.ioWriteOnMain = onMain }
            if mark == .contents || (mark == .commit && sample.closesAtCommit) {
                state.open = nil
                return sample
            }
            state.open = sample
            return nil
        }
        if let finished { emit(finished, complete: true) }
    }

    /// The open sample is written at its commit mark (now, when that already ran): the key
    /// went to a text view, so no terminal echo follows (`debug.key` with `probe: "commit"`).
    public func closeAtCommit() {
        guard output != nil else { return }
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
