#if !canImport(os)
import Foundation

/// Linux stand-in for `os.OSAllocatedUnfairLock`, which ships only with Apple
/// SDKs. It covers the subset our code calls (`init(initialState:)`,
/// `init(uncheckedState:)`, `withLock`, `withLockUnchecked`) over an `NSLock`,
/// so sources compile unchanged on Linux. Apple builds never see
/// this type: they keep the real unfair lock.
public final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    public init(initialState: State) where State: Sendable {
        state = initialState
    }

    public init(uncheckedState: State) {
        state = uncheckedState
    }

    public func withLock<R>(_ body: @Sendable (inout State) throws -> R) rethrows -> R where R: Sendable {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

extension OSAllocatedUnfairLock where State == Void {
    public convenience init() {
        self.init(uncheckedState: ())
    }

    public func withLock<R>(_ body: @Sendable () throws -> R) rethrows -> R where R: Sendable {
        try withLockUnchecked { _ in try body() }
    }
}
#endif
