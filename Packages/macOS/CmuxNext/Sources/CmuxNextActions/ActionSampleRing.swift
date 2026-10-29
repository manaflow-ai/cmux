/// The fixed ring ``ActionBudgetMonitor`` writes each run into: allocated and filled once at init,
/// then written in place. A raw buffer, not an `Array`: a reader's copy of an array would make the
/// next write copy the whole ring (an allocation on the action's path).
///
/// Not `Sendable`: only its monitor (main actor) holds it. `nonisolated`, so its `deinit` frees
/// the buffer wherever the monitor is released.
nonisolated final class ActionSampleRing {
    /// Slots, a power of two.
    let capacity: Int
    private let mask: UInt64
    private let slots: UnsafeMutablePointer<ActionRunSlot>

    /// A ring of at least `capacity` slots (rounded up to a power of two, at least 1).
    init(capacity: Int) {
        var size = 1
        while size < max(capacity, 1) { size <<= 1 }
        self.capacity = size
        mask = UInt64(size - 1)
        slots = .allocate(capacity: size)
        slots.initialize(repeating: .empty, count: size)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
    }

    /// Writes `sample` into the slot of run `sequence`.
    func write(_ sample: ActionRunSlot, at sequence: UInt64) {
        slots[Int(truncatingIfNeeded: sequence & mask)] = sample
    }

    /// The sample in the slot of run `sequence`.
    func read(at sequence: UInt64) -> ActionRunSlot {
        slots[Int(truncatingIfNeeded: sequence & mask)]
    }
}
