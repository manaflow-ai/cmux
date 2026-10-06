import Foundation
import Synchronization

/// Opt-in keystroke-to-frame timeline for one terminal key at a time
/// (`CMUX_NEXT_TYPING_PROBE=<csv path>`). Off by default: every hop then
/// costs one load of ``isEnabled``.
///
/// A sample opens at a key-down and records the first time each later hop
/// runs: AppKit dispatch, Ghostty's write callback, the attach socket
/// submit, the echo's decode on the attach reader, its main-thread hop,
/// its parse on the output lane, and the first `layer.contents` set after
/// that parse (the frame Core Animation commits). The row is appended when
/// that frame lands. Drive it with keys paced wider than one round trip;
/// a key that arrives while a sample is open closes the old one unfinished.
/// Times are milliseconds after the event's own timestamp (seconds since
/// boot, the same clock as `CLOCK_UPTIME_RAW`).
public final class TypingLatencyProbe: Sendable {
    public static let shared = TypingLatencyProbe(path: ProcessInfo.processInfo.environment["CMUX_NEXT_TYPING_PROBE"])

    public static var isEnabled: Bool { shared.output != nil }

    public enum Mark: Int, CaseIterable, Sendable {
        case dispatchStart, dispatchEnd, ioWrite, socketSubmit, outputDecoded, outputMain, outputParsed, contents

        var column: String {
            switch self {
            case .dispatchStart: "dispatch_start_ms"
            case .dispatchEnd: "dispatch_end_ms"
            case .ioWrite: "io_write_ms"
            case .socketSubmit: "socket_submit_ms"
            case .outputDecoded: "output_decoded_ms"
            case .outputMain: "output_main_ms"
            case .outputParsed: "output_parsed_ms"
            case .contents: "contents_ms"
            }
        }

        /// The hop that must have run first, so output from an earlier key
        /// is not taken for this key's echo.
        var after: Mark? {
            switch self {
            case .dispatchStart, .dispatchEnd, .ioWrite: nil
            case .socketSubmit: .ioWrite
            case .outputDecoded: .socketSubmit
            case .outputMain: .outputDecoded
            case .outputParsed: .outputMain
            case .contents: .outputParsed
            }
        }
    }

    private struct Sample {
        var index: Int
        var event: UInt64
        var marks = [UInt64?](repeating: nil, count: Mark.allCases.count)
        var ioWriteOnMain = false
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
        let header = (["index", "complete", "io_write_on_main"] + Mark.allCases.map(\.column)).joined(separator: ",") + "\n"
        handle.write(Data(header.utf8))
    }

    /// Opens a sample for a key-down whose `NSEvent.timestamp` is `eventTimestamp`.
    public func keyDown(eventTimestamp: TimeInterval) {
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
            if mark == .contents {
                state.open = nil
                return sample
            }
            state.open = sample
            return nil
        }
        if let finished { emit(finished, complete: true) }
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
