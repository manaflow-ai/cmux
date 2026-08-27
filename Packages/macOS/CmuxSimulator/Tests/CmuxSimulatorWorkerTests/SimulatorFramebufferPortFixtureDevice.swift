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
