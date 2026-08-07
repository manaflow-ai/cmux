internal import CmuxFoundationAtomicsC

/// A macOS 14-compatible atomic raw pointer that does not own its pointee.
///
/// C11 owns every storage access, so the wrapper is safe to send between
/// isolation domains. Callers remain responsible for retaining any object
/// represented by the pointer until a successful exchange removes it.
public final class AtomicRawPointerValue: @unchecked Sendable {
    // The storage address never changes, and all pointee access occurs through
    // the C11 atomic API rather than overlapping Swift `inout` accesses.
    nonisolated(unsafe) private let storage:
        UnsafeMutablePointer<CmuxAtomicRawPointerStorage>

    /// Creates an atomic pointer value.
    ///
    /// - Parameter initialValue: The unowned pointer returned until replaced.
    public init(_ initialValue: UnsafeRawPointer? = nil) {
        storage = .allocate(capacity: 1)
        CmuxAtomicRawPointerInitialize(storage, initialValue)
    }

    deinit {
        storage.deallocate()
    }

    /// Returns the current unowned pointer with acquire ordering.
    @inline(__always)
    public func loadAcquire() -> UnsafeRawPointer? {
        CmuxAtomicRawPointerLoadAcquire(storage)
    }

    /// Atomically replaces `expected` with `desired` using acquire-release ordering.
    ///
    /// - Parameters:
    ///   - expected: The pointer that must still be stored for replacement to occur.
    ///   - desired: The unowned replacement pointer.
    /// - Returns: `true` when the replacement occurred, otherwise `false`.
    @inline(__always)
    public func compareExchange(
        expected: UnsafeRawPointer?,
        desired: UnsafeRawPointer?
    ) -> Bool {
        CmuxAtomicRawPointerCompareExchange(storage, expected, desired)
    }
}
