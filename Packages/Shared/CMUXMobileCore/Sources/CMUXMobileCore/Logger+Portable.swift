#if !canImport(os)
import Foundation

/// The `os.Logger` surface this package and its dependents use, for platforms
/// without the `os` module. Messages go to standard error.
public struct Logger: Sendable {
    private let prefix: String

    public init(subsystem: String, category: String) {
        prefix = "[\(subsystem):\(category)]"
    }

    public init() {
        prefix = ""
    }

    public func log(_ message: OSLogMessage) {
        emit(.default, message)
    }

    public func log(level: OSLogType, _ message: OSLogMessage) {
        emit(level, message)
    }

    public func trace(_ message: OSLogMessage) {
        emit(.debug, message)
    }

    public func debug(_ message: OSLogMessage) {
        emit(.debug, message)
    }

    public func info(_ message: OSLogMessage) {
        emit(.info, message)
    }

    public func notice(_ message: OSLogMessage) {
        emit(.default, message)
    }

    public func warning(_ message: OSLogMessage) {
        emit(.error, message)
    }

    public func error(_ message: OSLogMessage) {
        emit(.error, message)
    }

    public func critical(_ message: OSLogMessage) {
        emit(.fault, message)
    }

    public func fault(_ message: OSLogMessage) {
        emit(.fault, message)
    }

    private func emit(_ level: OSLogType, _ message: OSLogMessage) {
        let line = "\(prefix) \(level.label): \(message.text)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// The log levels of `os.OSLogType`.
public struct OSLogType: Equatable, Hashable, Sendable {
    let label: String

    public static let `default` = OSLogType(label: "default")
    public static let info = OSLogType(label: "info")
    public static let debug = OSLogType(label: "debug")
    public static let error = OSLogType(label: "error")
    public static let fault = OSLogType(label: "fault")
}

/// Whether an interpolated log value is written out or redacted.
public struct OSLogPrivacy: Equatable, Sendable {
    let redacts: Bool

    public static let auto = OSLogPrivacy(redacts: false)
    public static let `public` = OSLogPrivacy(redacts: false)
    public static let `private` = OSLogPrivacy(redacts: true)
    public static let sensitive = OSLogPrivacy(redacts: true)
}

/// A log message built from a string literal with optional `privacy:`
/// annotations on its interpolations.
public struct OSLogMessage: ExpressibleByStringInterpolation, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var text: String

        public init(literalCapacity: Int, interpolationCount _: Int) {
            text = ""
            text.reserveCapacity(literalCapacity)
        }

        public mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        public mutating func appendInterpolation<T>(
            _ value: @autoclosure () -> T,
            privacy: OSLogPrivacy = .auto
        ) {
            text += privacy.redacts ? "<private>" : String(describing: value())
        }
    }

    let text: String

    public init(stringLiteral value: String) {
        text = value
    }

    public init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }
}
#endif
