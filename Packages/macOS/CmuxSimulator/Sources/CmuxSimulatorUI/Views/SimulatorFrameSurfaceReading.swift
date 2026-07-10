import IOSurface

protocol SimulatorFrameSurfaceReading: AnyObject {
    var latestFrame: (surface: IOSurface, sequence: UInt64)? { get }
}
