internal import Darwin

/// A `VM_FLAGS_PURGABLE` region of this task: while volatile its pages are outside `phys_footprint` and
/// the kernel empties the whole region when it needs memory, without waking cmux.
public final class VirtualMemoryPurgeablePages: PurgeablePages {
    /// vm_statistics.h and vm_purgable.h by value: the C macros with a cast do not import into Swift.
    private static let flagsAnywhere: Int32 = 0x1
    private static let flagsPurgable: Int32 = 0x2
    private static let setState: Int32 = 0
    private static let nonVolatile: Int32 = 0
    private static let volatile: Int32 = 1
    private static let empty: Int32 = 2
    private static let stateMask: Int32 = 0x3

    private let address: UInt
    public let byteCount: Int
    public var isPurgeable: Bool { true }

    /// Maps a new purgeable region, zero-filled and non-volatile.
    ///
    /// - Parameter byteCount: The bytes it maps (rounded up to whole pages by the kernel).
    public init?(byteCount: Int) {
        guard byteCount > 0 else { return nil }
        var address: vm_address_t = 0
        // SAFETY: vm_allocate writes the new region's address into `address` during the call.
        let result = unsafe vm_allocate(mach_task_self_, &address, vm_size_t(byteCount), Self.flagsAnywhere | Self.flagsPurgable)
        guard result == KERN_SUCCESS, address != 0 else { return nil }
        self.address = address
        self.byteCount = byteCount
    }

    deinit {
        _ = vm_deallocate(mach_task_self_, address, vm_size_t(byteCount))
    }

    public var baseAddress: UnsafeMutableRawPointer? {
        // SAFETY: `address` is the start of this object's mapping, which lives until its deinit.
        unsafe UnsafeMutableRawPointer(bitPattern: address)
    }

    public func makeVolatile() {
        _ = previousState(after: Self.volatile)
    }

    /// Non-volatile again; false when the region was emptied (or the state cannot be read: a miss is safe).
    public func makeNonVolatile() -> Bool {
        previousState(after: Self.nonVolatile).map { $0 & Self.stateMask != Self.empty } ?? false
    }

    /// Empties the region now, as memory pressure would (tests).
    public func purge() {
        _ = previousState(after: Self.empty)
    }

    /// Sets the region's purgeable state; the state it had before, nil when the call failed.
    private func previousState(after state: Int32) -> Int32? {
        var value = state
        // SAFETY: vm_purgable_control reads the new state from `value` and writes the previous one back into it
        // during the call.
        let result = unsafe vm_purgable_control(mach_task_self_, address, Self.setState, &value)
        return result == KERN_SUCCESS ? value : nil
    }
}
