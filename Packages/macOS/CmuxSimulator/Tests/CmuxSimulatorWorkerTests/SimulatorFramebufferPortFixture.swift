import Foundation

final class SimulatorFramebufferPortFixture {
    private let io: SimulatorFramebufferPortFixtureIO
    private let descriptor: SimulatorFramebufferPortFixtureDescriptor
    let device: NSObject

    var didRequestCurrentPorts: Bool { io.didRequestCurrentPorts }

    init() {
        let descriptor = SimulatorFramebufferPortFixtureDescriptor()
        self.descriptor = descriptor
        let forwardingDescriptor = SimulatorFramebufferPortFixtureForwardingDescriptor(
            target: descriptor
        )
        let port = SimulatorFramebufferPortFixtureForwardingPort(descriptor: forwardingDescriptor)
        let io = SimulatorFramebufferPortFixtureIO(ports: [port])
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
