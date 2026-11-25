#if !canImport(OSLog)
import Foundation

/// Minimal unified-log surface for Linux package tests, where Apple's OSLog
/// module is unavailable. Messages are intentionally discarded.
enum OSLogType {
    case debug
    case error
}

enum OSLogPrivacy {
    case `public`
}

extension DefaultStringInterpolation {
    mutating func appendInterpolation<T>(_ value: T, privacy: OSLogPrivacy) {
        appendInterpolation(value)
    }
}

struct Logger: Sendable {
    init(subsystem: String, category: String) {}

    func log(level: OSLogType, _ message: String) {}
    func info(_ message: String) {}
    func error(_ message: String) {}
}
#endif
