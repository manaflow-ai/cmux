import Foundation

final class SimulatorFramebufferPortFixtureForwardingProperties: NSObject,
    SimulatorFramebufferPortFixtureProperties
{
    private let target: NSObject & SimulatorFramebufferPortFixtureProperties

    init(target: NSObject & SimulatorFramebufferPortFixtureProperties) {
        self.target = target
        super.init()
    }

    var orientation: UInt32 {
        get { target.orientation }
        set { target.orientation = newValue }
    }

    override func responds(to selector: Selector!) -> Bool {
        target.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        target
    }

}
