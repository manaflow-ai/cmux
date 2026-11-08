import Foundation

/// Deep-copies a contiguous packed frame into host-owned bytes.
protocol SimulatorFrameByteCopying: Sendable {
    /// Copies exactly `count` bytes from a validated mapped slot.
    func copyBytes(from address: UnsafeRawPointer, count: Int) async -> Data?
}
