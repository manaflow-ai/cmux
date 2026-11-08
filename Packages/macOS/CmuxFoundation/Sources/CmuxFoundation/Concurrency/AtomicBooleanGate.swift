internal import CmuxFoundationAtomicsC

/// A macOS 14-compatible atomic Boolean used as a lock-free disabled-path gate.
///
/// Reads use relaxed ordering because callers recheck authoritative state under
/// their own synchronization after observing `true`. Stores use release ordering
/// so a transition to `false` is visible before the owner disables its state.
public final class AtomicBooleanGate: @unchecked Sendable {
    // The pointer is allocated once and never changes. C11 owns every access to
    // its pointee, so concurrent calls do not form overlapping Swift `inout`
    // accesses and Thread Sanitizer sees the atomic synchronization directly.
    nonisolated(unsafe) private let storage: UnsafeMutablePointer<CmuxAtomicBooleanStorage>

    /// Creates a gate with the supplied initial value.
    ///
    /// - Parameter initialValue: The value returned until the first store.
    public init(_ initialValue: Bool) {
        storage = .allocate(capacity: 1)
        CmuxAtomicBooleanInitialize(storage, initialValue)
    }

    deinit {
        storage.deallocate()
    }

    /// Returns the current value with relaxed memory ordering.
    @inline(__always)
    public func loadRelaxed() -> Bool {
        CmuxAtomicBooleanLoadRelaxed(storage)
    }

    /// Returns the current value with acquire ordering.
    ///
    /// Use this when observing `true` activates behavior that must see a
    /// preceding release-published transition before the caller proceeds.
    @inline(__always)
    public func loadAcquire() -> Bool {
        CmuxAtomicBooleanLoadAcquire(storage)
    }

    /// Publishes a new value with release memory ordering.
    ///
    /// - Parameter value: The value subsequent loads should observe.
    @inline(__always)
    public func storeRelease(_ value: Bool) {
        CmuxAtomicBooleanStoreRelease(storage, value)
    }

    /// Atomically replaces `expected` with `desired`.
    ///
    /// - Returns: `true` when this call observed `expected` and performed the
    ///   transition, otherwise `false`.
    @inline(__always)
    public func compareExchange(expected: Bool, desired: Bool) -> Bool {
        CmuxAtomicBooleanCompareExchange(storage, expected, desired)
    }
}
