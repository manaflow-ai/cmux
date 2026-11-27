#if !canImport(os)
import Foundation

/// The `OSAllocatedUnfairLock` surface this package and its dependents use, for
/// platforms without the `os` module.
// lint:allow lock - stands in for os.OSAllocatedUnfairLock where it is unavailable.
public final class OSAllocatedUnfairLock<State>: @unchecked Sendable { // crash-allow: `state` is read and written only inside withLock, under `mutex`
    private let mutex = NSLock()
    private var state: State

    public init(initialState: State) {
        state = initialState
    }

    public init(uncheckedState: State) {
        state = uncheckedState
    }

    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        mutex.lock()
        defer { mutex.unlock() }
        return try body(&state)
    }

    public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try withLock(body)
    }
}
#endif
