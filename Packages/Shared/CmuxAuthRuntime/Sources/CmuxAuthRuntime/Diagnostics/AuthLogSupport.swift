#if !canImport(OSLog)
import Foundation
import Synchronization

/// Lock surface used by the auth runtime on platforms without Apple's `os` module: a `Mutex` holds the
/// state, so the class is Sendable with no unchecked conformance.
final class OSAllocatedUnfairLock<State: Sendable>: Sendable {
    private let mutex: Mutex<State>

    init(initialState: State) {
        mutex = Mutex(initialState)
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try mutex.withLock { try body(&$0) }
    }
}

/// Foundation on Linux has no `String(localized:)`; the Linux shape shows the English default.
extension String {
    init(localized key: StaticString, defaultValue: String, bundle: Bundle) {
        self = defaultValue
    }
}

/// Minimal unified-log surface for Linux package tests, where Apple's OSLog
/// module is unavailable. Messages are intentionally discarded.
enum OSLogType {
    case debug
    case error
}

enum OSLogPrivacy {
    case `public`
    case `private`
}

extension DefaultStringInterpolation {
    mutating func appendInterpolation<T>(_ value: T, privacy: OSLogPrivacy) {
        appendInterpolation(value)
    }
}

struct Logger: Sendable {
    init(subsystem: String, category: String) {}

    func log(level: OSLogType, _ message: String) {}
    func debug(_ message: String) {}
    func info(_ message: String) {}
    func error(_ message: String) {}
}
#endif
