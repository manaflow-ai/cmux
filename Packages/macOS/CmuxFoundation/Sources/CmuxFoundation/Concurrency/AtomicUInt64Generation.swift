internal import CmuxFoundationAtomicsC

/// A macOS 14-compatible atomic generation counter for synchronous lifecycle boundaries.
///
/// Use this counter when synchronous callbacks need to tag work without an
/// actor hop while another isolation domain can invalidate all earlier work.
/// C11 atomics own every pointee access, making the stable allocation safe to
/// share across concurrency domains despite Swift's inability to prove that
/// safety for the imported storage type.
public final class AtomicUInt64Generation: @unchecked Sendable {
    // The pointer is allocated once and never changes. C11 owns every access to
    // its pointee, so concurrent calls cannot form overlapping Swift accesses.
    nonisolated(unsafe) private let storage: UnsafeMutablePointer<CmuxAtomicUInt64Storage>

    /// Creates a generation counter with the supplied initial value.
    ///
    /// - Parameter initialValue: The first value returned by ``loadRelaxed()``.
    public init(_ initialValue: UInt64 = 0) {
        storage = .allocate(capacity: 1)
        CmuxAtomicUInt64Initialize(storage, initialValue)
    }

    deinit {
        storage.deallocate()
    }

    /// Returns the current generation with relaxed memory ordering.
    ///
    /// The generation is an identity token only; it does not publish access to
    /// other memory, so stronger ordering would add cost without a guarantee.
    @inline(__always)
    public func loadRelaxed() -> UInt64 {
        CmuxAtomicUInt64LoadRelaxed(storage)
    }

    /// Atomically advances the generation and returns its new value.
    ///
    /// The counter saturates at `UInt64.max` instead of wrapping, preserving
    /// monotonic comparisons for the lifetime of the process.
    ///
    /// - Returns: The generation immediately following the prior value, or
    ///   `UInt64.max` when the counter is already saturated.
    @inline(__always)
    public func advanceRelaxed() -> UInt64 {
        CmuxAtomicUInt64AdvanceRelaxed(storage)
    }
}
