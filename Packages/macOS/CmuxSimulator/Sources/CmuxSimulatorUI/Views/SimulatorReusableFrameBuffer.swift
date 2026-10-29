import Darwin

// SAFETY: the allocation address and capacity are immutable. Ownership moves
// between one actor-isolated pool and one immutable Data value, so writes never
// overlap presentation reads.
final class SimulatorReusableFrameBuffer: @unchecked Sendable {
    let address: UnsafeMutableRawPointer
    let capacity: Int

    init?(capacity: Int) {
        guard capacity >= 0,
              let address = malloc(max(capacity, 1)) else { return nil }
        self.address = address
        self.capacity = capacity
    }

    deinit {
        free(address)
    }
}
