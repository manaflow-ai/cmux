import Darwin
import Foundation

/// Default deep copier for stable shared-memory frame slots.
struct SimulatorFrameByteCopier: SimulatorFrameByteCopying, Sendable {
    let pool: SimulatorFrameBufferPool

    init(maximumBufferCount: Int = 3) {
        pool = SimulatorFrameBufferPool(maximumBufferCount: maximumBufferCount)
    }

    func copyBytes(from address: UnsafeRawPointer, count: Int) async -> Data? {
        guard count >= 0,
              let buffer = await pool.acquire(byteCount: count) else { return nil }
        memcpy(buffer.address, address, count)
        return Data(
            bytesNoCopy: buffer.address,
            count: count,
            deallocator: .custom { [pool, buffer] _, _ in
                Task { await pool.recycle(buffer) }
            }
        )
    }
}
