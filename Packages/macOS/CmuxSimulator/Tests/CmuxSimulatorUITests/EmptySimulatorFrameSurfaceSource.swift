import IOSurface

@testable import CmuxSimulatorUI

final class EmptySimulatorFrameSurfaceSource: SimulatorFrameSurfaceReading {
    var latestFrame: (surface: IOSurface, sequence: UInt64)? { nil }
}
