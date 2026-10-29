import Foundation

final class SimulatorFramebufferPortFixtureScreenProperties: NSObject,
    SimulatorFramebufferPortFixtureProperties
{
    private let identifier: UInt32
    private let type: UInt64
    var orientation: UInt32 = 1

    init(screenID: UInt32, screenType: UInt64) {
        identifier = screenID
        type = screenType
    }

    @objc dynamic func screenID() -> UInt32 { identifier }
    @objc dynamic func screenType() -> UInt64 { type }
    @objc dynamic func uiOrientation() -> UInt32 { orientation }
}
