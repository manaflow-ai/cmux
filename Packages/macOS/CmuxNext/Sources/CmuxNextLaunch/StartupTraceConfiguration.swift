public import Foundation

/// What `CMUX_TRACE_STARTUP` asks for: how long after process start the startup trace records, and the
/// file it writes (plans/cmux-next/chrome-parity/p08-startup.md, section E and task 004).
///
/// `CMUX_TRACE_STARTUP=<seconds>[,<file>]` (empty: 5 s; `0` or anything but a number: off) and `CMUX_TRACE_STARTUP_FILE=<file>`;
/// the default file is `~/Library/Logs/cmux/startup-<pid>.json`. Chrome's `--trace-startup` and
/// `--trace-startup-duration` / `--trace-startup-file` (components/tracing/common/trace_startup_config.cc).
public struct StartupTraceConfiguration: Sendable, Equatable {
    public static let environmentKey = "CMUX_TRACE_STARTUP"
    public static let fileEnvironmentKey = "CMUX_TRACE_STARTUP_FILE"
    /// Chrome's default `--trace-startup-duration` is 5 s too.
    public static let defaultSeconds: Double = 5
    /// The longest recording a launch may ask for.
    public static let maximumSeconds: Double = 600

    /// How long after process start the trace closes.
    public var seconds: Double
    /// The Chrome Trace Event JSON file.
    public var file: URL
    /// Records the preallocated ring holds before the files lane drains it.
    public var capacity: Int
    /// The write size: the ring drains into the file in writes of about this many bytes.
    public var chunkBytes: Int
    /// The longest a record waits in the ring before a drain writes it, so a crash loses at most this much.
    public var flushInterval: Duration

    public init(seconds: Double = Self.defaultSeconds, file: URL, capacity: Int = 16_384, chunkBytes: Int = 64 * 1_024,
                flushInterval: Duration = .milliseconds(250)) {
        self.seconds = seconds
        self.file = file
        self.capacity = max(1, capacity)
        self.chunkBytes = max(1_024, chunkBytes)
        self.flushInterval = max(.milliseconds(10), flushInterval)
    }

    /// The configuration the environment asks for, or nil when `CMUX_TRACE_STARTUP` is unset, `0` or not a
    /// number of seconds (`false`, `off`: a mistaken value never turns tracing on).
    ///
    /// Unset costs one lookup: nothing else is read and nothing is allocated.
    ///
    /// - Parameters:
    ///   - lookup: Reads one environment variable (the app passes `getenv`).
    ///   - home: The home folder, read only when the default file is used.
    ///   - pid: This process's id, for the default file name.
    public static func fromEnvironment(_ lookup: (String) -> String?, home: @autoclosure () -> URL,
                                       pid: Int32) -> StartupTraceConfiguration? {
        guard let raw = lookup(environmentKey) else { return nil }
        let parts = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let first = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var seconds = defaultSeconds
        if !first.isEmpty {
            guard let value = Double(first), value > 0 else { return nil }
            seconds = min(value, maximumSeconds)
        }
        let path = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : lookup(fileEnvironmentKey)
        let file: URL
        if let path, !path.isEmpty {
            file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            file = home().appending(path: "Library/Logs/cmux/startup-\(pid).json")
        }
        return StartupTraceConfiguration(seconds: seconds, file: file)
    }

    /// `getenv`, for ``fromEnvironment(_:home:pid:)``: no environment dictionary is built.
    public static func processEnvironment(_ key: String) -> String? {
        getenv(key).map { String(cString: $0) }
    }
}
