#if !canImport(os)
import Foundation

/// Linux stand-in for `os.OSAllocatedUnfairLock`, which ships only with Apple
/// SDKs. It covers the subset this module calls (`init(initialState:)`,
/// `init(uncheckedState:)`, `withLock`, `withLockUnchecked`) over an `NSLock`,
/// so the module's sources compile unchanged on Linux. Apple builds never see
/// this type: they keep the real unfair lock.
// lint:allow lock: the Linux stand-in for os.OSAllocatedUnfairLock itself; Apple builds use the real lock.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    // lint:allow lock: corelibs has no unfair lock; NSLock is the Linux primitive.
    private let lock = NSLock()
    private var state: State

    init(initialState: State) where State: Sendable {
        state = initialState
    }

    init(uncheckedState: State) {
        state = uncheckedState
    }

    func withLock<R>(_ body: @Sendable (inout State) throws -> R) rethrows -> R where R: Sendable {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

// lint:allow lock: the Void-state initializer of the same Linux stand-in.
extension OSAllocatedUnfairLock where State == Void {
    convenience init() {
        self.init(uncheckedState: ())
    }

    func withLock<R>(_ body: @Sendable () throws -> R) rethrows -> R where R: Sendable {
        try withLockUnchecked { _ in try body() }
    }
}
#endif
