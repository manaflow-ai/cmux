import Foundation

final class SimulatorFramebufferPortFixturePort: NSObject {
    private let displayDescriptor: AnyObject

    init(descriptor: AnyObject) {
        displayDescriptor = descriptor
    }

    @objc dynamic func descriptor() -> AnyObject { displayDescriptor }
}
