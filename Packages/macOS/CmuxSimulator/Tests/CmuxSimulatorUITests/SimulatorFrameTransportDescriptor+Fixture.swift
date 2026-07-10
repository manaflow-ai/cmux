import CmuxSimulator
import Foundation

func simulatorFrameTransportDescriptor(
    _ identifier: UInt32
) -> SimulatorFrameTransportDescriptor {
    SimulatorFrameTransportDescriptor(
        sharedMemoryName: String(
            format: "/cmux-sim-frame-%012llx",
            UInt64(identifier)
        ),
        surfaceIdentifiers: [identifier, identifier &+ 1, identifier &+ 2],
        width: 390,
        height: 844
    )
}
