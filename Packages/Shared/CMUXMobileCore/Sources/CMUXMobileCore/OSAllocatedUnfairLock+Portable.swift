#if !canImport(os)
internal import CmuxSafeConcurrency

/// The `OSAllocatedUnfairLock` surface this package and its dependents use, for
/// platforms without the `os` module. It forwards to CmuxSafeConcurrency's
/// `PlatformLock`, the lock under its portable `Mutex`.
// lint:allow lock - stands in for os.OSAllocatedUnfairLock where it is unavailable; forwards to CmuxSafeConcurrency.PlatformLock.
public final class OSAllocatedUnfairLock<State>: @unchecked Sendable { // crash-allow: `state` is read and written only inside withLock, under `lock`
    private let lock = PlatformLock()
    private var state: State

    public init(initialState: State) {
        state = initialState
    }

    public init(uncheckedState: State) {
        state = uncheckedState
    }

    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try lock.withLock { () throws -> R in try body(&state) }
    }

    public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try withLock(body)
    }
}
#endif
