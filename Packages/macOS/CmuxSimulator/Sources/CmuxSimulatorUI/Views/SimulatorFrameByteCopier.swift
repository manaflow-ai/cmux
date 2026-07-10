import Foundation

/// Default deep copier for stable shared-memory frame slots.
struct SimulatorFrameByteCopier: SimulatorFrameByteCopying, Sendable {
    func copyBytes(from address: UnsafeRawPointer, count: Int) -> Data {
        Data(bytes: address, count: count)
    }
}
