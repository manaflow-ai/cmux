internal import CmuxFoundationAtomicsC

/// A macOS 14-compatible UInt64 value for synchronous cross-isolation
/// instrumentation.
///
/// C11 atomics own every pointee access, so renderer callbacks can update the
/// value while UI diagnostics read it without a Swift data race or actor hop.
public final class AtomicUInt64Value: @unchecked Sendable {
    // The pointer is allocated once and never changes. C11 owns every access to
    // its pointee, so concurrent calls cannot form overlapping Swift accesses.
    nonisolated(unsafe) private let storage: UnsafeMutablePointer<CmuxAtomicUInt64Storage>

    /// Creates an atomic value.
    ///
    /// - Parameter initialValue: The value returned until the first mutation.
    public init(_ initialValue: UInt64 = 0) {
        storage = .allocate(capacity: 1)
        CmuxAtomicUInt64Initialize(storage, initialValue)
    }

    deinit {
        storage.deallocate()
    }

    /// Returns the current value with relaxed memory ordering.
    @inline(__always)
    public func loadRelaxed() -> UInt64 {
        CmuxAtomicUInt64LoadRelaxed(storage)
    }

    /// Replaces the current value with relaxed memory ordering.
    ///
    /// - Parameter value: The value subsequent loads should observe.
    @inline(__always)
    public func storeRelaxed(_ value: UInt64) {
        CmuxAtomicUInt64StoreRelaxed(storage, value)
    }

    /// Atomically replaces the value with acquire-release ordering.
    ///
    /// - Parameter value: The replacement value.
    /// - Returns: The value that this call replaced.
    @inline(__always)
    public func exchangeAcquiringAndReleasing(_ value: UInt64) -> UInt64 {
        CmuxAtomicUInt64ExchangeAcquiringAndReleasing(storage, value)
    }

    /// Replaces an expected value with acquire-release ordering.
    ///
    /// - Parameters:
    ///   - expected: The value that must currently be stored.
    ///   - desired: The replacement written when `expected` matches.
    /// - Returns: Whether this call performed the replacement.
    @inline(__always)
    public func compareExchangeAcquiringAndReleasing(
        expected: UInt64,
        desired: UInt64
    ) -> Bool {
        CmuxAtomicUInt64CompareExchangeAcquiringAndReleasing(
            storage,
            expected,
            desired
        )
    }

    /// Atomically increments the value with wrapping UInt64 arithmetic.
    ///
    /// - Returns: The value after the increment.
    @inline(__always)
    public func wrappingIncrementRelaxed() -> UInt64 {
        CmuxAtomicUInt64IncrementRelaxed(storage)
    }

    /// Atomically increments the value when it is below `upperBound`.
    ///
    /// - Returns: `true` when this call claimed one count below the bound.
    @inline(__always)
    public func incrementIfBelow(_ upperBound: UInt64) -> Bool {
        CmuxAtomicUInt64IncrementIfBelow(storage, upperBound)
    }

    /// Atomically decrements a positive value.
    ///
    /// - Returns: `true` when this call released one existing count.
    @inline(__always)
    public func decrementIfPositive() -> Bool {
        CmuxAtomicUInt64DecrementIfPositive(storage)
    }
}
