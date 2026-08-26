import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator frame buffer pool")
struct SimulatorFrameBufferPoolTests {
    @Test("Target-scale frames stay within three reusable allocations")
    func targetScaleAllocationBound() async throws {
        let byteCount = 1_290 * 2_796 * 4
        let pool = SimulatorFrameBufferPool(maximumBufferCount: 3)
        let first = try #require(await pool.acquire(byteCount: byteCount))
        let second = try #require(await pool.acquire(byteCount: byteCount))
        let third = try #require(await pool.acquire(byteCount: byteCount))

        #expect(await pool.acquire(byteCount: byteCount) == nil)
        #expect(await pool.allocatedBufferCount == 3)

        await pool.recycle(second)
        let reused = try #require(await pool.acquire(byteCount: byteCount))

        #expect(reused === second)
        #expect(await pool.allocatedBufferCount == 3)
        withExtendedLifetime((first, third, reused)) {}
    }
}
