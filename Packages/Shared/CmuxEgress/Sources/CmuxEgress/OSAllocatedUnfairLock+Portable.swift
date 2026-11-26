#if !canImport(os)
import Foundation

/// The `OSAllocatedUnfairLock` surface used by CmuxEgress on platforms without the `os` module.
// lint:allow lock - stands in for os.OSAllocatedUnfairLock where it is unavailable.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable { // crash-allow: state is accessed only while mutex is held
    private let mutex = NSLock()
    private var state: State

    init(initialState: State) {
        state = initialState
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        mutex.lock()
        defer { mutex.unlock() }
        return try body(&state)
    }
}
#endif
