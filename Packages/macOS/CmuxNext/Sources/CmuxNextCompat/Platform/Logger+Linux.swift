// `Logger` for every module that imports CmuxNextCompat (p15-oracle.md section H). On Apple platforms this is
// `os.Logger` itself, re-exported: no wrapper, and the unified log keeps its levels and privacy. Where `os`
// does not exist (Linux) this file and the OSLog*+Linux.swift files give the same source surface, `privacy:`,
// `format:` and `align:` included, and write one line per message to standard error, as Chromium's LOG() does
// on Linux (base/logging.cc, LOG_TO_STDERR).

#if canImport(os)
@_exported public import os
#else
internal import Foundation

/// The `os.Logger` surface on Linux: the same initializer and level methods. A message's values are read only
/// when its level is written, as in the unified log, and a value whose privacy is private, sensitive or (for
/// text) auto is written as `<private>`.
public struct Logger: Sendable {
    private let subsystem: String
    private let category: String
    private let sink: any LogSink

    /// A logger for `category` in `subsystem` that writes to standard error at the level `CMUX_LOG_LEVEL`
    /// names (`debug`, `info`, `default`, `error` or `fault`; `default` when it is unset or unknown).
    public init(subsystem: String, category: String) {
        // SAFETY: getenv's string is copied before the call returns.
        let level = unsafe getenv("CMUX_LOG_LEVEL").map { unsafe String(cString: $0) }
        self.init(subsystem: subsystem, category: category, sink: StandardErrorLogSink(environmentLevel: level))
    }

    /// A logger with no subsystem or category.
    public init() {
        self.init(subsystem: "", category: "")
    }

    /// A logger for `category` in `subsystem` that writes to `sink`.
    public init(subsystem: String, category: String, sink: any LogSink) {
        self.subsystem = subsystem
        self.category = category
        self.sink = sink
    }

    /// Writes `message` at the default level.
    public func log(_ message: OSLogMessage) {
        log(level: .default, message)
    }

    /// Writes `message` at `level`.
    public func log(level: OSLogType, _ message: OSLogMessage) {
        guard sink.isEnabled(level) else { return }
        sink.write(level: level, subsystem: subsystem, category: category, message: message.render())
    }

    /// Writes `message` at the debug level.
    public func trace(_ message: OSLogMessage) {
        log(level: .debug, message)
    }

    /// Writes `message` at the debug level.
    public func debug(_ message: OSLogMessage) {
        log(level: .debug, message)
    }

    /// Writes `message` at the info level.
    public func info(_ message: OSLogMessage) {
        log(level: .info, message)
    }

    /// Writes `message` at the default level.
    public func notice(_ message: OSLogMessage) {
        log(level: .default, message)
    }

    /// Writes `message` at the error level.
    public func warning(_ message: OSLogMessage) {
        log(level: .error, message)
    }

    /// Writes `message` at the error level.
    public func error(_ message: OSLogMessage) {
        log(level: .error, message)
    }

    /// Writes `message` at the fault level.
    public func critical(_ message: OSLogMessage) {
        log(level: .fault, message)
    }

    /// Writes `message` at the fault level.
    public func fault(_ message: OSLogMessage) {
        log(level: .fault, message)
    }
}

/// Where a Linux ``Logger`` writes its rendered lines: standard error by default, another sink in tests or in a
/// headless host that collects the log.
public protocol LogSink: Sendable {
    /// Whether a message at `level` is written. A disabled level's values are never read.
    func isEnabled(_ level: OSLogType) -> Bool

    /// Writes one rendered message.
    func write(level: OSLogType, subsystem: String, category: String, message: String)
}
#endif
