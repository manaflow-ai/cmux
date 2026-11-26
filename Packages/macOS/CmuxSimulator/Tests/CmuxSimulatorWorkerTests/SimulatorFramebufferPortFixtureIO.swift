import Foundation

final class SimulatorFramebufferPortFixtureIO: NSObject {
    private let ports: [NSObject]
    private(set) var didRequestCurrentPorts = false

    init(ports: [NSObject]) {
        self.ports = ports
    }

    @objc dynamic func updateIOPorts() {}
    @objc dynamic func deviceIOPorts() -> [AnyObject] { [] }

    @objc dynamic func ioPorts() -> [AnyObject] {
        didRequestCurrentPorts = true
        return ports
    }
}
