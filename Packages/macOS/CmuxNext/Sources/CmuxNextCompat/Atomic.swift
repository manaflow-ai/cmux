public import Atomics

/// A value that threads read and change without a data race, with the API
/// subset of `Synchronization.Atomic` (macOS 15) that cmux-next uses, so that
/// cmux-next runs on macOS 14 (plans/cmux-next/macos-floor.md).
///
/// It is lock-free and async-signal-safe: every operation is one hardware
/// atomic instruction from Apple's swift-atomics package, with the memory
/// ordering the call site names. The ordering types are the swift-atomics
/// ones, which have the same spelling as the system types. One difference:
/// ``add(_:ordering:)`` and ``subtract(_:ordering:)`` wrap on overflow
/// instead of trapping.
public struct Atomic<Value: AtomicValue>: ~Copyable {
    private let raw: UnsafeAtomic<Value>

    /// Makes an atomic that holds `initialValue`.
    public init(_ initialValue: Value) {
        raw = .create(initialValue)
    }

    deinit {
        raw.destroy()
    }

    /// Returns the current value.
    public borrowing func load(ordering: AtomicLoadOrdering) -> Value {
        raw.load(ordering: ordering)
    }

    /// Replaces the current value.
    public borrowing func store(_ desired: Value, ordering: AtomicStoreOrdering) {
        raw.store(desired, ordering: ordering)
    }

    /// Replaces the current value and returns the value it replaced.
    @discardableResult
    public borrowing func exchange(_ desired: Value, ordering: AtomicUpdateOrdering) -> Value {
        raw.exchange(desired, ordering: ordering)
    }

    /// Stores `desired` only when the current value equals `expected`.
    /// Returns whether it stored, and the value it found.
    @discardableResult
    public borrowing func compareExchange(
        expected: Value,
        desired: Value,
        ordering: AtomicUpdateOrdering
    ) -> (exchanged: Bool, original: Value) {
        raw.compareExchange(expected: expected, desired: desired, ordering: ordering)
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
        raw.compareExchange(
            expected: expected,
            desired: desired,
            successOrdering: successOrdering,
            failureOrdering: failureOrdering
        )
    }

    /// Like ``compareExchange(expected:desired:ordering:)``, but it may fail
    /// spuriously; use it in a retry loop.
    @discardableResult
    public borrowing func weakCompareExchange(
        expected: Value,
        desired: Value,
        ordering: AtomicUpdateOrdering
    ) -> (exchanged: Bool, original: Value) {
        raw.weakCompareExchange(expected: expected, desired: desired, ordering: ordering)
    }
}

extension Atomic: @unchecked Sendable {} // crash-allow: every access is a hardware atomic operation, as in Synchronization.Atomic

extension Atomic where Value: AtomicInteger {
    /// Adds `operand` (wraps on overflow).
    @discardableResult
    public borrowing func add(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        wrappingAdd(operand, ordering: ordering)
    }

    /// Subtracts `operand` (wraps on overflow).
    @discardableResult
    public borrowing func subtract(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        wrappingSubtract(operand, ordering: ordering)
    }

    /// Adds `operand` with wraparound.
    @discardableResult
    public borrowing func wrappingAdd(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        let old = raw.loadThenWrappingIncrement(by: operand, ordering: ordering)
        return (old, old &+ operand)
    }

    /// Subtracts `operand` with wraparound.
    @discardableResult
    public borrowing func wrappingSubtract(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        let old = raw.loadThenWrappingDecrement(by: operand, ordering: ordering)
        return (old, old &- operand)
    }
}

extension Atomic where Value == Bool {
    /// Sets the value to `value || operand`.
    @discardableResult
    public borrowing func logicalOr(_ operand: Bool, ordering: AtomicUpdateOrdering) -> (oldValue: Bool, newValue: Bool) {
        let old = raw.loadThenLogicalOr(with: operand, ordering: ordering)
        return (old, old || operand)
    }

    /// Sets the value to `value && operand`.
    @discardableResult
    public borrowing func logicalAnd(_ operand: Bool, ordering: AtomicUpdateOrdering) -> (oldValue: Bool, newValue: Bool) {
        let old = raw.loadThenLogicalAnd(with: operand, ordering: ordering)
        return (old, old && operand)
    }
}
