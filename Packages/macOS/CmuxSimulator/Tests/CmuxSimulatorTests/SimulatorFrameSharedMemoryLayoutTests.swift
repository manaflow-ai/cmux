import Testing
@testable import CmuxSimulator

@Suite("Simulator frame shared-memory layout")
struct SimulatorFrameSharedMemoryLayoutTests {
    @Test("Dimensions and total ring bytes stay bounded")
    func boundedGeometry() throws {
        #expect(throws: SimulatorFrameLayoutError.self) {
            _ = try SimulatorFrameSharedMemoryLayout(width: 16_385, height: 1)
        }
        #expect(throws: SimulatorFrameLayoutError.self) {
            _ = try SimulatorFrameSharedMemoryLayout(width: 16_384, height: 16_384)
        }
    }

    @Test("Descriptors must match the computed packed layout")
    func descriptorGeometry() throws {
        let layout = try SimulatorFrameSharedMemoryLayout(width: 390, height: 844)
        let descriptor = SimulatorFrameTransportDescriptor(
            sharedMemoryName: "/cmux-sim-frame-000000000001",
            width: layout.width,
            height: layout.height,
            bytesPerRow: layout.bytesPerRow,
            slotCount: layout.slotCount,
            sharedMemoryByteCount: layout.totalByteCount + 1
        )

        #expect(throws: SimulatorFrameLayoutError.self) {
            _ = try SimulatorFrameSharedMemoryLayout(descriptor: descriptor)
        }
    }
}
