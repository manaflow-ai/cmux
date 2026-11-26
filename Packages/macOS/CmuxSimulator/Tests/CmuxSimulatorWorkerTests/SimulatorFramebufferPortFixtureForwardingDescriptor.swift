import Foundation

final class SimulatorFramebufferPortFixtureForwardingDescriptor: NSObject {
    private let target: SimulatorFramebufferPortFixtureDescriptor
    private let forwardedSelectors = [
        NSSelectorFromString("framebufferSurface"),
        NSSelectorFromString("screenProperties"),
        NSSelectorFromString(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:" +
                "surfacesChangedCallback:propertiesChangedCallback:"
        ),
        NSSelectorFromString("unregisterScreenCallbacksWithUUID:"),
    ]

    init(target: SimulatorFramebufferPortFixtureDescriptor) {
        self.target = target
    }

    override func responds(to selector: Selector!) -> Bool {
        forwardedSelectors.contains(selector) || super.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedSelectors.contains(selector) { return target }
        return super.forwardingTarget(for: selector)
    }
}
