/// A value that threads read and change without a data race, with the API
/// subset of `Synchronization.Atomic` (macOS 15) that cmux-next uses, so that
/// cmux-next runs on macOS 14 (plans/cmux-next/macos-floor.md).
///
/// Each operation takes an `os_unfair_lock` for a few instructions. That is
/// at least as strong as every memory ordering, so the `ordering` arguments
/// only keep the call sites the same as with the system type. The lock is not
/// async-signal-safe: never touch an `Atomic` from a signal handler.
public struct Atomic<Value: Sendable>: ~Copyable {
    private let storage: LockedStorage<Value>

    /// Makes an atomic that holds `initialValue`.
    public init(_ initialValue: Value) {
        storage = LockedStorage(initialValue)
    }

    /// Returns the current value.
    public borrowing func load(ordering: AtomicLoadOrdering) -> Value {
        storage.lock()
        defer { storage.unlock() }
        return storage.pointer.pointee
    }

    /// Replaces the current value.
    public borrowing func store(_ desired: Value, ordering: AtomicStoreOrdering) {
        storage.lock()
        defer { storage.unlock() }
        storage.pointer.pointee = desired
    }

    /// Replaces the current value and returns the value it replaced.
    @discardableResult
    public borrowing func exchange(_ desired: Value, ordering: AtomicUpdateOrdering) -> Value {
        update { value in
            let original = value
            value = desired
            return original
        }
    }

    borrowing func update<Result>(_ body: (inout Value) -> Result) -> Result {
        storage.lock()
        defer { storage.unlock() }
        return body(&storage.pointer.pointee)
    }
}

extension Atomic: @unchecked Sendable {} // crash-allow: every operation holds the storage lock

extension Atomic where Value: Equatable {
    /// Stores `desired` only when the current value equals `expected`.
    /// Returns whether it stored, and the value it found.
    @discardableResult
    public borrowing func compareExchange(
        expected: Value,
        desired: Value,
        ordering: AtomicUpdateOrdering
    ) -> (exchanged: Bool, original: Value) {
        update { value in
            let original = value
            guard original == expected else { return (false, original) }
            value = desired
            return (true, original)
        }
    }

    /// ``compareExchange(expected:desired:ordering:)`` with separate orderings
    /// for the success and the failure case.
    @discardableResult
    public borrowing func compareExchange(
        expected: Value,
        desired: Value,
        successOrdering: AtomicUpdateOrdering,
        failureOrdering: AtomicLoadOrdering
    ) -> (exchanged: Bool, original: Value) {
        compareExchange(expected: expected, desired: desired, ordering: successOrdering)
    }

    /// The same as ``compareExchange(expected:desired:ordering:)``; it never
    /// fails spuriously.
    @discardableResult
    public borrowing func weakCompareExchange(
        expected: Value,
        desired: Value,
        ordering: AtomicUpdateOrdering
    ) -> (exchanged: Bool, original: Value) {
        compareExchange(expected: expected, desired: desired, ordering: ordering)
    }
}

extension Atomic where Value: FixedWidthInteger {
    /// Adds `operand`; traps on overflow, like the system type.
    @discardableResult
    public borrowing func add(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        update { value in
            let old = value
            value = old + operand
            return (old, value)
        }
    }

    /// Subtracts `operand`; traps on overflow, like the system type.
    @discardableResult
    public borrowing func subtract(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        update { value in
            let old = value
            value = old - operand
            return (old, value)
        }
    }

    /// Adds `operand` with wraparound.
    @discardableResult
    public borrowing func wrappingAdd(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        update { value in
            let old = value
            value = old &+ operand
            return (old, value)
        }
    }

    /// Subtracts `operand` with wraparound.
    @discardableResult
    public borrowing func wrappingSubtract(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        update { value in
            let old = value
            value = old &- operand
            return (old, value)
        }
    }
}

extension Atomic where Value == Bool {
    /// Sets the value to `value || operand`.
    @discardableResult
    public borrowing func logicalOr(_ operand: Bool, ordering: AtomicUpdateOrdering) -> (oldValue: Bool, newValue: Bool) {
        update { value in
            let old = value
            value = old || operand
            return (old, value)
        }
    }

    /// Sets the value to `value && operand`.
    @discardableResult
    public borrowing func logicalAnd(_ operand: Bool, ordering: AtomicUpdateOrdering) -> (oldValue: Bool, newValue: Bool) {
        update { value in
            let old = value
            value = old && operand
            return (old, value)
        }
    }
}

/// The memory ordering of an ``Atomic`` load. Same spelling as the system type.
public enum AtomicLoadOrdering: Sendable {
    case relaxed
    case acquiring
    case sequentiallyConsistent
}

/// The memory ordering of an ``Atomic`` store. Same spelling as the system type.
public enum AtomicStoreOrdering: Sendable {
    case relaxed
    case releasing
    case sequentiallyConsistent
}

/// The memory ordering of an ``Atomic`` read-modify-write operation. Same
/// spelling as the system type.
public enum AtomicUpdateOrdering: Sendable {
    case relaxed
    case acquiring
    case releasing
    case acquiringAndReleasing
    case sequentiallyConsistent
}
