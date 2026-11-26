import Foundation

final class SimulatorFramebufferPortFixtureDeviceType: NSObject {
    private let scale: Double

    init(mainScreenScale: Double) {
        scale = mainScreenScale
    }

    @objc dynamic func mainScreenScale() -> Double { scale }
}
