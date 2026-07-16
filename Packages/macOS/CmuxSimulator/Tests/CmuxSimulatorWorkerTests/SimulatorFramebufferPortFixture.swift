import Foundation

final class SimulatorFramebufferPortFixture {
    private let io: SimulatorFramebufferPortFixtureIO
    private let descriptor: SimulatorFramebufferPortFixtureDescriptor
    let device: NSObject

    var didRequestCurrentPorts: Bool { io.didRequestCurrentPorts }

    init(displays: [(screenID: UInt32, width: Int, height: Int)] = [(0, 8, 12)]) {
        let descriptors = displays.map {
            SimulatorFramebufferPortFixtureDescriptor(
                screenID: $0.screenID,
                width: $0.width,
                height: $0.height
            )
        }
        let descriptor = descriptors[0]
        self.descriptor = descriptor
        let ports = descriptors.map {
            SimulatorFramebufferPortFixtureForwardingPort(
                descriptor: SimulatorFramebufferPortFixtureForwardingDescriptor(target: $0)
            )
        }
        let io = SimulatorFramebufferPortFixtureIO(ports: ports)
        self.io = io
        device = SimulatorFramebufferPortFixtureDevice(io: io)
    }

    func publishFrame(width: Int, height: Int) {
        descriptor.publishFrame(width: width, height: height)
    }

    func removeSurface() {
        descriptor.removeSurface()
    }
}
