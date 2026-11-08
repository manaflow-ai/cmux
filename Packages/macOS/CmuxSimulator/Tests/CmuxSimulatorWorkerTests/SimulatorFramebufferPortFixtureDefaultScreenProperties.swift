import Foundation

final class SimulatorFramebufferPortFixtureDefaultScreenProperties: NSObject,
    SimulatorFramebufferPortFixtureProperties
{
    private let identifier: UInt32
    private let defaultScreen: Bool
    var orientation: UInt32 = 1

    init(screenID: UInt32, isDefault: Bool) {
        identifier = screenID
        defaultScreen = isDefault
    }

    @objc dynamic func screenID() -> UInt32 { identifier }
    @objc dynamic func isDefault() -> Bool { defaultScreen }
    @objc dynamic func uiOrientation() -> UInt32 { orientation }
}
