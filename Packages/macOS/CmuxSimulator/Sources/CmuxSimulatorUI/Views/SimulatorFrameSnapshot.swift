import Foundation

/// Immutable host-owned packed-BGRA frame bytes.
struct SimulatorFrameSnapshot: Equatable, Sendable {
    let pixels: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let sequence: UInt64
}
