import CmuxSimulator
import Foundation

func simulatorFrameTransportDescriptor(
    _ identifier: UInt32,
    width: Int = 390,
    height: Int = 844
) -> SimulatorFrameTransportDescriptor {
    let layout = try! SimulatorFrameSharedMemoryLayout(width: width, height: height)
    return SimulatorFrameTransportDescriptor(
        sharedMemoryName: String(
            format: "/cmux-sim-frame-%012llx",
            UInt64(identifier)
        ),
        width: width,
        height: height,
        bytesPerRow: layout.bytesPerRow,
        slotCount: layout.slotCount,
        sharedMemoryByteCount: layout.totalByteCount
    )
}
