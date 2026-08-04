import Foundation

final class SimulatorFramebufferPortFixtureForwardingPort: NSObject {
    private let target: SimulatorFramebufferPortFixturePort

    init(descriptor: AnyObject) {
        target = SimulatorFramebufferPortFixturePort(descriptor: descriptor)
    }

    override func responds(to selector: Selector!) -> Bool {
        selector == NSSelectorFromString("descriptor") || super.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if selector == NSSelectorFromString("descriptor") { return target }
        return super.forwardingTarget(for: selector)
    }
}
