import Darwin
import Foundation

/// Where each captured screen frame's time went, for the screen stream eval
/// (`scripts/measure/screen-stream-eval`; measurement only). When `CMUX_VNC_TIMING_LOG` names a file,
/// the host appends one JSON line per complete frame ScreenCaptureKit hands over: `input_us`, the last
/// viewer input posted before it (once); `shown_us`, the frame's display time; `arrived_us`, when the
/// capture handed it over, which is also when it goes to the encoder (ScreenStream pushes it in that
/// callback). All in µs of mach absolute time, so only their differences mean anything.
/// Unset, nothing is recorded.
final class CaptureTimingLog: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var inputUs: UInt64?
    private let timebase: mach_timebase_info_data_t

    /// The log `CMUX_VNC_TIMING_LOG` names in `environment`; nil when it is unset or can't be opened.
    convenience init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment["CMUX_VNC_TIMING_LOG"] else { return nil }
        self.init(path: path)
    }

    private init?(path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        self.handle = handle
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        timebase = base
    }

    private func microseconds(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1)) / 1000
    }

    /// A viewer input was posted now.
    func input() {
        let now = microseconds(mach_absolute_time())
        lock.withLock { inputUs = now }
    }

    /// A complete frame arrived now; `displayTime` is ScreenCaptureKit's, in mach absolute time.
    func frame(displayTime: UInt64?) {
        let arrived = microseconds(mach_absolute_time())
        let shown = displayTime.map { microseconds($0) }
        lock.withLock {
            var line: [String: Any] = ["arrived_us": arrived]
            if let shown { line["shown_us"] = shown }
            if let inputUs { line["input_us"] = inputUs }
            inputUs = nil
            guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
            handle.write(data + Data("\n".utf8))
        }
    }
}
