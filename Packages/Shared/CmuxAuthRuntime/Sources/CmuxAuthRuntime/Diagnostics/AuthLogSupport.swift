#if !canImport(OSLog)
import Foundation

/// Lock surface used by the auth runtime on platforms without Apple's `os` module.
// lint:allow lock - stands in for os.OSAllocatedUnfairLock where it is unavailable.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable { // crash-allow: `state` is read and written only inside withLock, under `mutex`
    private let mutex = NSLock()
    private var state: State

    init(initialState: State) {
        state = initialState
    }

    init(uncheckedState: State) {
        state = uncheckedState
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        mutex.lock()
        defer { mutex.unlock() }
        return try body(&state)
    }

    func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try withLock(body)
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
