public import Atomics
public import class CmuxSafeConcurrency.Invariant

/// A lock-free `UInt64` at an address the caller owns (a heap block or an mmap page): chunk cursors,
/// sequences, histogram buckets and crash keys in shared memory. ``Atomic`` allocates its own word on
/// the heap, so it cannot sit inside a mapped file; this slot wraps swift-atomics' `UnsafeAtomic(at:)`
/// over the caller's word instead, with ``Atomic``'s API spelling and orderings.
///
/// Chromium does the same for its persistent memory: `base/metrics/persistent_memory_allocator.cc`
/// keeps its `std::atomic` free pointer and block headers inside the mapped segment, and
/// `base/metrics/persistent_sample_map.cc` counts samples in place in that memory.
///
/// Every operation is `@inlinable` and always inlined, so a call site in another module with a
/// constant ordering compiles to one atomic instruction (a relaxed load is one plain `ldr`).
///
/// The slot does not own its memory: the word must stay mapped and 8-byte aligned while any copy of
/// the slot is used. Two slots over the same address are the same atomic.
@frozen
public struct AtomicPointerSlot: Sendable { // its one stored property, UnsafeAtomic, is Sendable (swift-atomics)
    @usableFromInline let raw: UnsafeAtomic<UInt64>

    /// Makes a slot over the word at `pointer`, which must be 8-byte aligned.
    @inlinable
    public init(_ pointer: UnsafeMutablePointer<UInt64>) {
        Invariant.debugCheck(unsafe Int(bitPattern: pointer) & (MemoryLayout<UInt64>.alignment - 1) == 0,
                             "atomic-pointer-slot-aligned", "AtomicPointerSlot needs an 8-byte aligned word")
        // SAFETY: the slot touches only the one aligned UInt64 at `pointer`, which the caller keeps mapped while the
        // slot is used (the type's contract above); UInt64's atomic representation has UInt64's size and alignment.
        raw = unsafe UnsafeAtomic<UInt64>(at: UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: UInt64.AtomicRepresentation.self))
    }

    /// Returns the current value.
    @inlinable @inline(__always)
    public func load(ordering: AtomicLoadOrdering) -> UInt64 {
        switch ordering {
        case .relaxed: raw.load(ordering: .relaxed)
        case .acquiring: raw.load(ordering: .acquiring)
        case .sequentiallyConsistent: raw.load(ordering: .sequentiallyConsistent)
        }
    }

    /// Replaces the current value.
    @inlinable @inline(__always)
    public func store(_ desired: UInt64, ordering: AtomicStoreOrdering) {
        switch ordering {
        case .relaxed: raw.store(desired, ordering: .relaxed)
        case .releasing: raw.store(desired, ordering: .releasing)
        case .sequentiallyConsistent: raw.store(desired, ordering: .sequentiallyConsistent)
        }
    }

    /// Replaces the current value and returns the value it replaced.
    @inlinable @inline(__always) @discardableResult
    public func exchange(_ desired: UInt64, ordering: AtomicUpdateOrdering) -> UInt64 {
        switch ordering {
        case .relaxed: raw.exchange(desired, ordering: .relaxed)
        case .acquiring: raw.exchange(desired, ordering: .acquiring)
        case .releasing: raw.exchange(desired, ordering: .releasing)
        case .acquiringAndReleasing: raw.exchange(desired, ordering: .acquiringAndReleasing)
        case .sequentiallyConsistent: raw.exchange(desired, ordering: .sequentiallyConsistent)
        }
    }

    /// Adds `operand` (wraps on overflow) and returns the old and new values.
    @inlinable @inline(__always) @discardableResult
    public func add(_ operand: UInt64, ordering: AtomicUpdateOrdering) -> (oldValue: UInt64, newValue: UInt64) {
        let old: UInt64
        switch ordering {
        case .relaxed: old = raw.loadThenWrappingIncrement(by: operand, ordering: .relaxed)
        case .acquiring: old = raw.loadThenWrappingIncrement(by: operand, ordering: .acquiring)
        case .releasing: old = raw.loadThenWrappingIncrement(by: operand, ordering: .releasing)
        case .acquiringAndReleasing: old = raw.loadThenWrappingIncrement(by: operand, ordering: .acquiringAndReleasing)
        case .sequentiallyConsistent: old = raw.loadThenWrappingIncrement(by: operand, ordering: .sequentiallyConsistent)
        }
        return (old, old &+ operand)
    }

    /// Subtracts `operand` (wraps on overflow) and returns the old and new values.
    @inlinable @inline(__always) @discardableResult
    public func subtract(_ operand: UInt64, ordering: AtomicUpdateOrdering) -> (oldValue: UInt64, newValue: UInt64) {
        let old: UInt64
        switch ordering {
        case .relaxed: old = raw.loadThenWrappingDecrement(by: operand, ordering: .relaxed)
        case .acquiring: old = raw.loadThenWrappingDecrement(by: operand, ordering: .acquiring)
        case .releasing: old = raw.loadThenWrappingDecrement(by: operand, ordering: .releasing)
        case .acquiringAndReleasing: old = raw.loadThenWrappingDecrement(by: operand, ordering: .acquiringAndReleasing)
        case .sequentiallyConsistent: old = raw.loadThenWrappingDecrement(by: operand, ordering: .sequentiallyConsistent)
        }
        return (old, old &- operand)
    }

    /// Stores `desired` only when the current value equals `expected`; returns whether it stored and the
    /// value it found.
    @inlinable @inline(__always) @discardableResult
    public func compareExchange(expected: UInt64, desired: UInt64,
                                ordering: AtomicUpdateOrdering) -> (exchanged: Bool, original: UInt64) {
        switch ordering {
        case .relaxed: raw.compareExchange(expected: expected, desired: desired, ordering: .relaxed)
        case .acquiring: raw.compareExchange(expected: expected, desired: desired, ordering: .acquiring)
        case .releasing: raw.compareExchange(expected: expected, desired: desired, ordering: .releasing)
        case .acquiringAndReleasing: raw.compareExchange(expected: expected, desired: desired, ordering: .acquiringAndReleasing)
        case .sequentiallyConsistent: raw.compareExchange(expected: expected, desired: desired, ordering: .sequentiallyConsistent)
        }
    }

    /// Like ``compareExchange(expected:desired:ordering:)``, but it may fail spuriously; use it in a
    /// retry loop.
    @inlinable @inline(__always) @discardableResult
    public func weakCompareExchange(expected: UInt64, desired: UInt64,
                                    ordering: AtomicUpdateOrdering) -> (exchanged: Bool, original: UInt64) {
        switch ordering {
        case .relaxed: raw.weakCompareExchange(expected: expected, desired: desired, ordering: .relaxed)
        case .acquiring: raw.weakCompareExchange(expected: expected, desired: desired, ordering: .acquiring)
        case .releasing: raw.weakCompareExchange(expected: expected, desired: desired, ordering: .releasing)
        case .acquiringAndReleasing: raw.weakCompareExchange(expected: expected, desired: desired, ordering: .acquiringAndReleasing)
        case .sequentiallyConsistent: raw.weakCompareExchange(expected: expected, desired: desired, ordering: .sequentiallyConsistent)
        }
    }
}
