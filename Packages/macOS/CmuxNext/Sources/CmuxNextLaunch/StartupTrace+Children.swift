import CmuxNextCompat
public import Foundation

/// The startup traces of the processes the launch starts: the daemon a cold launch spawns and Chromium's
/// browser process (p08-startup task 099). Chrome hands `--trace-startup` to its children through the trace
/// config and buffer handles (components/tracing/common/trace_startup_config.cc); cmux's daemon and Chromium
/// are not children Chrome's tracing reaches, so each writes its own Chrome Trace Event JSON file next to the
/// app's and `scripts/cmux-next/trace.py` merges the three on one clock (`CLOCK_UPTIME_RAW` microseconds).
///
/// ```swift
/// if let chromium = trace?.childTrace(.chromium) {
///     switches += ["trace-startup-duration=\(chromium.seconds)", "trace-startup-file=\(chromium.file.path)"]
/// }
/// ```
extension StartupTrace {
    /// A process the launch starts that writes its own startup trace.
    public enum Child: String, Sendable, CaseIterable {
        /// The cmux-tui owner a cold launch spawns (`server ensure`).
        case daemon
        /// Chromium's browser process (in the app, or in the Chromium Host): its `--trace-startup` file.
        case chromium

        /// The file name's suffix, which `trace.py` reads the source from (`startup_source`).
        var fileSuffix: String {
            switch self {
            case .daemon: "daemon"
            case .chromium: "cef"
            }
        }
    }

    /// What a child's startup trace records: how long from now, and the file it writes.
    public struct ChildTrace: Sendable, Equatable {
        /// Whole seconds until the app's trace closes, at least 1 (Chromium's `--trace-startup-duration`
        /// takes whole seconds).
        public var seconds: Int
        public var file: URL

        public init(seconds: Int, file: URL) {
            self.seconds = seconds
            self.file = file
        }
    }

    /// `CLOCK_UPTIME_RAW` nanoseconds when the trace closes: process start + its seconds. The daemon's launcher
    /// keeps it, so the owner it spawns gets the seconds left at the spawn, and none after it.
    public var deadlineNanos: UInt64 { processStartNanos &+ UInt64(configuration.seconds * 1e9) }

    /// `child`'s startup trace, asked as the child starts: until the app's own trace closes, into the file next to
    /// the app's (``StartupTraceConfiguration/childFile(_:)``). Nil once the app's trace closed or its deadline
    /// passed, so a Chromium that starts late records nothing. One atomic load and one clock read: callers ask on
    /// the main thread.
    public func childTrace(_ child: Child) -> ChildTrace? {
        guard recording.load(ordering: .relaxed) else { return nil }
        let end = deadlineNanos
        let current = uptimeNanos
        guard end > current else { return nil }
        let (whole, part) = (end - current).quotientAndRemainder(dividingBy: 1_000_000_000)
        return ChildTrace(seconds: max(1, Int(clamping: whole + (part > 0 ? 1 : 0))), file: configuration.childFile(child))
    }
}

extension StartupTraceConfiguration {
    /// `child`'s file, next to the app's: `startup-app.json` gives `startup-daemon.json` and `startup-cef.json`,
    /// `startup-<pid>.json` gives `startup-<pid>-daemon.json` and `startup-<pid>-cef.json`.
    public func childFile(_ child: StartupTrace.Child) -> URL {
        var stem = file.deletingPathExtension().lastPathComponent
        if stem.hasSuffix("-app") { stem.removeLast("-app".count) }
        return file.deletingLastPathComponent().appending(path: "\(stem)-\(child.fileSuffix).json")
    }
}
