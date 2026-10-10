public import Atomics

/// A value that threads read and change without a data race, with the API
/// subset of `Synchronization.Atomic` (macOS 15) that cmux-next uses, so that
/// cmux-next runs on macOS 14 (plans/cmux-next/macos-floor.md).
///
/// It is lock-free and async-signal-safe: every operation is one hardware
/// atomic instruction from Apple's swift-atomics package, with the memory
/// ordering the call site names. swift-atomics needs a constant ordering in
/// each call, so every method switches over this module's ordering enums
/// (same spelling as the system types) to a constant one. Differences from the
/// system type: ``add(_:ordering:)`` and ``subtract(_:ordering:)`` wrap on
/// overflow instead of trapping, and the two-ordering compare-exchange uses
/// the success ordering for both outcomes (it is at least as strong).
public struct Atomic<Value: AtomicValue>: ~Copyable where Value.AtomicRepresentation.Value == Value {
    private let raw: UnsafeAtomic<Value>

    /// Makes an atomic that holds `initialValue`.
    public init(_ initialValue: Value) {
        raw = UnsafeAtomic<Value>.create(initialValue)
    }

    deinit {
        raw.destroy()
    }

    /// Returns the current value.
    public borrowing func load(ordering: AtomicLoadOrdering) -> Value {
        switch ordering {
        case .relaxed: raw.load(ordering: .relaxed)
        case .acquiring: raw.load(ordering: .acquiring)
        case .sequentiallyConsistent: raw.load(ordering: .sequentiallyConsistent)
        }
    }

    /// Replaces the current value.
    public borrowing func store(_ desired: Value, ordering: AtomicStoreOrdering) {
        switch ordering {
        case .relaxed: raw.store(desired, ordering: .relaxed)
        case .releasing: raw.store(desired, ordering: .releasing)
        case .sequentiallyConsistent: raw.store(desired, ordering: .sequentiallyConsistent)
        }
    }

    /// Replaces the current value and returns the value it replaced.
    @discardableResult
    public borrowing func exchange(_ desired: Value, ordering: AtomicUpdateOrdering) -> Value {
        switch ordering {
        case .relaxed: raw.exchange(desired, ordering: .relaxed)
        case .acquiring: raw.exchange(desired, ordering: .acquiring)
        case .releasing: raw.exchange(desired, ordering: .releasing)
        case .acquiringAndReleasing: raw.exchange(desired, ordering: .acquiringAndReleasing)
        case .sequentiallyConsistent: raw.exchange(desired, ordering: .sequentiallyConsistent)
        }
    }

    /// Stores `desired` only when the current value equals `expected`.
    /// Returns whether it stored, and the value it found.
    @discardableResult
    public borrowing func compareExchange(
        expected: Value,
        desired: Value,
        ordering: AtomicUpdateOrdering
    ) -> (exchanged: Bool, original: Value) {
        switch ordering {
        case .relaxed: raw.compareExchange(expected: expected, desired: desired, ordering: .relaxed)
        case .acquiring: raw.compareExchange(expected: expected, desired: desired, ordering: .acquiring)
        case .releasing: raw.compareExchange(expected: expected, desired: desired, ordering: .releasing)
        case .acquiringAndReleasing: raw.compareExchange(expected: expected, desired: desired, ordering: .acquiringAndReleasing)
        case .sequentiallyConsistent: raw.compareExchange(expected: expected, desired: desired, ordering: .sequentiallyConsistent)
        }
    }

    /// ``compareExchange(expected:desired:ordering:)`` with separate orderings
    /// for the success and the failure case; the success ordering serves both.
    @discardableResult
    public borrowing func compareExchange(
        expected: Value,
        desired: Value,
        successOrdering: AtomicUpdateOrdering,
        failureOrdering: AtomicLoadOrdering
    ) -> (exchanged: Bool, original: Value) {
        compareExchange(expected: expected, desired: desired, ordering: successOrdering)
    }

    /// Like ``compareExchange(expected:desired:ordering:)``, but it may fail
    /// spuriously; use it in a retry loop.
    @discardableResult
    public borrowing func weakCompareExchange(
        expected: Value,
        desired: Value,
        ordering: AtomicUpdateOrdering
    ) -> (exchanged: Bool, original: Value) {
        switch ordering {
        case .relaxed: raw.weakCompareExchange(expected: expected, desired: desired, ordering: .relaxed)
        case .acquiring: raw.weakCompareExchange(expected: expected, desired: desired, ordering: .acquiring)
        case .releasing: raw.weakCompareExchange(expected: expected, desired: desired, ordering: .releasing)
        case .acquiringAndReleasing: raw.weakCompareExchange(expected: expected, desired: desired, ordering: .acquiringAndReleasing)
        case .sequentiallyConsistent: raw.weakCompareExchange(expected: expected, desired: desired, ordering: .sequentiallyConsistent)
        }
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
        let old: Value
        switch ordering {
        case .relaxed: old = raw.loadThenWrappingIncrement(by: operand, ordering: .relaxed)
        case .acquiring: old = raw.loadThenWrappingIncrement(by: operand, ordering: .acquiring)
        case .releasing: old = raw.loadThenWrappingIncrement(by: operand, ordering: .releasing)
        case .acquiringAndReleasing: old = raw.loadThenWrappingIncrement(by: operand, ordering: .acquiringAndReleasing)
        case .sequentiallyConsistent: old = raw.loadThenWrappingIncrement(by: operand, ordering: .sequentiallyConsistent)
        }
        return (old, old &+ operand)
    }

    /// Subtracts `operand` with wraparound.
    @discardableResult
    public borrowing func wrappingSubtract(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        let old: Value
        switch ordering {
        case .relaxed: old = raw.loadThenWrappingDecrement(by: operand, ordering: .relaxed)
        case .acquiring: old = raw.loadThenWrappingDecrement(by: operand, ordering: .acquiring)
        case .releasing: old = raw.loadThenWrappingDecrement(by: operand, ordering: .releasing)
        case .acquiringAndReleasing: old = raw.loadThenWrappingDecrement(by: operand, ordering: .acquiringAndReleasing)
        case .sequentiallyConsistent: old = raw.loadThenWrappingDecrement(by: operand, ordering: .sequentiallyConsistent)
        }
        return (old, old &- operand)
    }
}

extension Atomic where Value == Bool {
    /// Sets the value to `value || operand`.
    @discardableResult
    public borrowing func logicalOr(_ operand: Bool, ordering: AtomicUpdateOrdering) -> (oldValue: Bool, newValue: Bool) {
        let old: Bool
        switch ordering {
        case .relaxed: old = raw.loadThenLogicalOr(with: operand, ordering: .relaxed)
        case .acquiring: old = raw.loadThenLogicalOr(with: operand, ordering: .acquiring)
        case .releasing: old = raw.loadThenLogicalOr(with: operand, ordering: .releasing)
        case .acquiringAndReleasing: old = raw.loadThenLogicalOr(with: operand, ordering: .acquiringAndReleasing)
        case .sequentiallyConsistent: old = raw.loadThenLogicalOr(with: operand, ordering: .sequentiallyConsistent)
        }
        return (old, old || operand)
    }

    /// Sets the value to `value && operand`.
    @discardableResult
    public borrowing func logicalAnd(_ operand: Bool, ordering: AtomicUpdateOrdering) -> (oldValue: Bool, newValue: Bool) {
        let old: Bool
        switch ordering {
        case .relaxed: old = raw.loadThenLogicalAnd(with: operand, ordering: .relaxed)
        case .acquiring: old = raw.loadThenLogicalAnd(with: operand, ordering: .acquiring)
        case .releasing: old = raw.loadThenLogicalAnd(with: operand, ordering: .releasing)
        case .acquiringAndReleasing: old = raw.loadThenLogicalAnd(with: operand, ordering: .acquiringAndReleasing)
        case .sequentiallyConsistent: old = raw.loadThenLogicalAnd(with: operand, ordering: .sequentiallyConsistent)
        }
        return (old, old && operand)
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
