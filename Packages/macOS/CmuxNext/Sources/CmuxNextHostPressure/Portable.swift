#if !canImport(os)
import Foundation

/// The `OSAllocatedUnfairLock` surface this package and its tests use, for
/// platforms without the `os` module (the Linux package lane; tests reach it through @testable).
/// Never built for an Apple platform, where `os` has the real one.
// lint:allow lock - stands in for os.OSAllocatedUnfairLock where it is unavailable.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable { // crash-allow: `state` is read and written only inside withLock, under `mutex`
    // concurrency-allow: Linux only (no os module); held only around an in-memory read or write of `state`, never across IO or await
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
