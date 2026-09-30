import CmuxSimulator
import Foundation

func simulatorFrameTransportDescriptor(
    _ identifier: UInt32,
    width: Int = 390,
    height: Int = 844
) -> SimulatorFrameTransportDescriptor {
    let layout: SimulatorFrameSharedMemoryLayout
    do {
        layout = try SimulatorFrameSharedMemoryLayout(width: width, height: height)
    } catch {
        preconditionFailure(
            "Invalid Simulator frame fixture dimensions \(width)x\(height): \(error)"
        )
    }
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
