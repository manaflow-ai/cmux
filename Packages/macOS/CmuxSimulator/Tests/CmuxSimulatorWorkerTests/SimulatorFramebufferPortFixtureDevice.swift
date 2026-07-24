import Foundation

final class SimulatorFramebufferPortFixtureDevice: NSObject {
    private let client: SimulatorFramebufferPortFixtureIO

    init(io: SimulatorFramebufferPortFixtureIO) {
        client = io
    }

    @objc dynamic func io() -> AnyObject { client }
}
