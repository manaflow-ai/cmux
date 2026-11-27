#if !canImport(os)
import Foundation

/// The `OSAllocatedUnfairLock` surface this target uses (a copy of CMUXMobileCore's), for
/// platforms without the `os` module.
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
#endif
