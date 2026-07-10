import IOSurface

@testable import CmuxSimulatorUI

final class EmptySimulatorFrameSurfaceSource: SimulatorFrameSurfaceReading {
    let latestFrame: (surface: IOSurface, sequence: UInt64)?

    init(latestFrame: (surface: IOSurface, sequence: UInt64)? = nil) {
        self.latestFrame = latestFrame
    }
}
