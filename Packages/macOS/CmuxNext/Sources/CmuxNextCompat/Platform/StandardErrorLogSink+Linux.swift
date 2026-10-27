// The Linux Logger's default sink and its levels (Logger+Linux.swift).

#if !canImport(os)
internal import Foundation

/// The default ``LogSink``: one `[subsystem:category] level: message` line per message on standard error, from
/// `minimumLevel` up.
public struct StandardErrorLogSink: LogSink {
    /// The lowest level written.
    public let minimumLevel: OSLogType

    /// A sink that writes `minimumLevel` and the levels above it.
    public init(minimumLevel: OSLogType = .default) {
        self.minimumLevel = minimumLevel
    }

    /// A sink whose lowest level is the one `name` names (``OSLogType/init(name:)``), `.default` when `name` is
    /// nil or unknown.
    public init(environmentLevel name: String?) {
        self.init(minimumLevel: name.flatMap(OSLogType.init(name:)) ?? .default)
    }

    public func isEnabled(_ level: OSLogType) -> Bool {
        level.severity >= minimumLevel.severity
    }

    /// Writes the line with one `write(2)` (FileHandle loops only on a short write), so lines from different
    /// threads do not interleave up to PIPE_BUF on a pipe. A failed write drops the line, as a full log would.
    public func write(level: OSLogType, subsystem: String, category: String, message: String) {
        let line = "[\(subsystem):\(category)] \(level.name): \(message)\n"
        // blocking-allow: the blocking detector reports through Logger, so a checked write would report itself (os.Logger's role on Darwin)
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }
}

/// The levels of `os.OSLogType`, with its raw values.
public struct OSLogType: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The level `name` names (`debug`, `info`, `default`, `error` or `fault`, any case), nil for another name.
    public init?(name: String) {
        switch name.lowercased() {
        case "debug": self = .debug
        case "info": self = .info
        case "default", "notice": self = .default
        case "error": self = .error
        case "fault": self = .fault
        default: return nil
        }
    }

    public static let `default` = OSLogType(rawValue: 0x00)
    public static let info = OSLogType(rawValue: 0x01)
    public static let debug = OSLogType(rawValue: 0x02)
    public static let error = OSLogType(rawValue: 0x10)
    public static let fault = OSLogType(rawValue: 0x11)

    /// The level's name in a written line.
    public var name: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .error: "error"
        case .fault: "fault"
        default: "default"
        }
    }

    /// The order of the levels, debug lowest (the raw values do not sort that way).
    var severity: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .error: 3
        case .fault: 4
        default: 2
        }
    }
}
#endif
