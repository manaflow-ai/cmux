import CmuxSimulator
import Foundation

protocol SimulatorAccessibilityBridging: Sendable {
    func attach(device: NSObject) -> Bool
    func detach()
    func resetAccessibilityConnection()
    func foregroundApplication() throws -> SimulatorApplicationInfo?
    func accessibilitySnapshot(
        display: SimulatorDisplayMetadata
    ) throws -> SimulatorAccessibilitySnapshot
}

extension SimulatorAccessibilityBridge: SimulatorAccessibilityBridging {}
