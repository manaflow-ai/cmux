public import Foundation

/// Chromium's own startup trace while the app's `CMUX_TRACE_STARTUP` records (p08-startup task 099): the
/// browser process starts with Chrome's startup tracing switches (components/tracing/common/tracing_switches.cc)
/// and writes a Chrome Trace Event JSON file at the end of `seconds` (content/browser/tracing/
/// startup_tracing_controller.cc). Its timestamps are `TimeTicks` (mach_absolute_time, the app's
/// `CLOCK_UPTIME_RAW`), so `scripts/cmux-next/trace.py` puts it on the app's clock beside the app's file and the
/// daemon's `daemon.*` launch marks. Without one (``CEFRuntimeSource/startupTrace`` nil, or nil when Chromium
/// starts) the browser process gets no tracing switch.
public nonisolated struct ChromiumStartupTrace: Sendable, Equatable {
    /// `--trace-startup-duration`: whole seconds, at least 1.
    public var seconds: Int
    /// `--trace-startup-file`.
    public var file: URL

    public init(seconds: Int, file: URL) {
        self.seconds = max(1, seconds)
        self.file = file
    }

    /// The browser-process switches: Chromium's default categories (`--trace-startup` with no value), and the
    /// format named, JSON, the one `trace.py` reads (the other, `proto`, it does not).
    var switches: [String] {
        ["trace-startup", "trace-startup-duration=\(seconds)", "trace-startup-file=\(file.path)", "trace-startup-format=json"]
    }
}
