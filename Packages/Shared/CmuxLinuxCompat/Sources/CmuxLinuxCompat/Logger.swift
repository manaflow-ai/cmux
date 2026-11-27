#if !canImport(os)
import Foundation

/// Linux stand-in for `os.Logger`, covering what our code calls:
/// `Logger(subsystem:category:)`, the level methods and `privacy:`
/// interpolation. Apple routes these to the unified log; Linux has none, so
/// messages are dropped unless `CMUX_LOG_STDERR=1`, which writes them to
/// standard error with private values redacted as Apple does outside debug.
public struct Logger: Sendable {
    public let subsystem: String
    public let category: String

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    public init() {
        self.init(subsystem: "", category: "")
    }

    public func log(level: OSLogType = .default, _ message: OSLogMessage) {
        guard Logger.writesToStandardError else { return }
        let line = "[\(subsystem):\(category)] \(level.name): \(message.rendered)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    public func log(_ message: OSLogMessage) { log(level: .default, message) }
    public func trace(_ message: OSLogMessage) { log(level: .debug, message) }
    public func debug(_ message: OSLogMessage) { log(level: .debug, message) }
    public func info(_ message: OSLogMessage) { log(level: .info, message) }
    public func notice(_ message: OSLogMessage) { log(level: .default, message) }
    public func warning(_ message: OSLogMessage) { log(level: .error, message) }
    public func error(_ message: OSLogMessage) { log(level: .error, message) }
    public func critical(_ message: OSLogMessage) { log(level: .fault, message) }
    public func fault(_ message: OSLogMessage) { log(level: .fault, message) }

    static let writesToStandardError = ProcessInfo.processInfo.environment["CMUX_LOG_STDERR"] == "1"
}

public struct OSLogType: Sendable, Equatable {
    let name: String
    public static let `default` = OSLogType(name: "default")
    public static let info = OSLogType(name: "info")
    public static let debug = OSLogType(name: "debug")
    public static let error = OSLogType(name: "error")
    public static let fault = OSLogType(name: "fault")
}

public struct OSLogPrivacy: Sendable, Equatable {
    public enum Mask: Sendable, Equatable { case hash, none }
    let redacts: Bool
    public static let `public` = OSLogPrivacy(redacts: false)
    public static let auto = OSLogPrivacy(redacts: false)
    public static let `private` = OSLogPrivacy(redacts: true)
    public static let sensitive = OSLogPrivacy(redacts: true)
    public static func `private`(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(redacts: true) }
    public static func auto(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(redacts: false) }
    public static func sensitive(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(redacts: true) }
}

public struct OSLogMessage: ExpressibleByStringInterpolation, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var text = ""
        public init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }
        public mutating func appendLiteral(_ literal: String) { text += literal }
        public mutating func appendInterpolation<T>(_ value: @autoclosure () -> T, privacy: OSLogPrivacy = .auto) {
            text += privacy.redacts ? "<private>" : String(describing: value())
        }
        public mutating func appendInterpolation<T>(
            _ value: @autoclosure () -> T, format: OSLogFormat, privacy: OSLogPrivacy = .auto
        ) {
            appendInterpolation(value(), privacy: privacy)
        }
    }

    let rendered: String
    public init(stringLiteral value: String) { rendered = value }
    public init(stringInterpolation: StringInterpolation) { rendered = stringInterpolation.text }
}

/// Accepted and ignored: Linux renders every value with `String(describing:)`.
// lint:allow namespace-type: mirrors os.OSLogFormat's static members (`.fixed`, `.hex`) that call sites pass.
public struct OSLogFormat: Sendable {
    public static let `public` = OSLogFormat()
    public static func fixed(precision: Int) -> OSLogFormat { OSLogFormat() }
    public static func hex(includePrefix: Bool = false, uppercase: Bool = false) -> OSLogFormat { OSLogFormat() }
    public static let decimal = OSLogFormat()
}
#endif
