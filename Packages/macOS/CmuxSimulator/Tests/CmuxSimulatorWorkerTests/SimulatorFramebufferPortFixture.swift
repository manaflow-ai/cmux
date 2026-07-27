import Foundation

final class SimulatorFramebufferPortFixture {
    private let io: SimulatorFramebufferPortFixtureIO
    private let descriptors: [SimulatorFramebufferPortFixtureDescriptor]
    let device: NSObject

    var didRequestCurrentPorts: Bool { io.didRequestCurrentPorts }
    var screenPropertiesReadCount: Int {
        descriptors.reduce(0) { $0 + $1.screenPropertiesReadCount }
    }

    init(
        displays: [(screenID: UInt32, screenType: UInt64, width: Int, height: Int)] = [
            (0, 0, 8, 12)
        ],
        propertiesAvailableAfterRegistration: Bool = false,
        usesDefaultScreenFlag: Bool = false,
        usesForwardingScreenProperties: Bool = false
    ) {
        let descriptors = displays.map {
            SimulatorFramebufferPortFixtureDescriptor(
                screenID: $0.screenID,
                screenType: $0.screenType,
                width: $0.width,
                height: $0.height,
                propertiesAvailableAfterRegistration: propertiesAvailableAfterRegistration,
                usesDefaultScreenFlag: usesDefaultScreenFlag,
                usesForwardingScreenProperties: usesForwardingScreenProperties
            )
        }
        self.descriptors = descriptors
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
        descriptors[0].publishFrame(width: width, height: height)
    }

    func removeSurface() {
        descriptors[0].removeSurface()
    }

    func publishOrientation(_ rawValue: UInt32, displayIndex: Int) {
        descriptors[displayIndex].publishOrientation(rawValue)
    }
}
