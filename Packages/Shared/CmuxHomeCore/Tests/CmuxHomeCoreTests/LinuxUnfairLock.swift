#if !canImport(os)
import Foundation

/// Linux has no `os` module: the tests' `OSAllocatedUnfairLock` there is an `NSLock` around the state,
/// with the same calls (`withLock`, `withLockUnchecked`) the Apple one gives.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) { state = initialState }
    init(uncheckedState: State) { state = uncheckedState }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try withLock(body)
    }
}
#endif
