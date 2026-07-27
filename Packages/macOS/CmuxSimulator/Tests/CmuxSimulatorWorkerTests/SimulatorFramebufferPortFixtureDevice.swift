import Foundation

final class SimulatorFramebufferPortFixtureDevice: NSObject {
    private let client: SimulatorFramebufferPortFixtureIO
    private let type: SimulatorFramebufferPortFixtureDeviceType

    init(io: SimulatorFramebufferPortFixtureIO, mainScreenScale: Double) {
        client = io
        type = SimulatorFramebufferPortFixtureDeviceType(
            mainScreenScale: mainScreenScale
        )
    }

    @objc dynamic func io() -> AnyObject { client }
    @objc dynamic func deviceType() -> AnyObject { type }
}

private final class SimulatorFramebufferPortFixtureDeviceType: NSObject {
    private let scale: Double

    init(mainScreenScale: Double) {
        scale = mainScreenScale
    }

    @objc dynamic func mainScreenScale() -> Double { scale }
}
