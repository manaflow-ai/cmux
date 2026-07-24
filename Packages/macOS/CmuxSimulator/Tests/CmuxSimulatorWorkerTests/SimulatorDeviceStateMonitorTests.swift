import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator device-state notifications")
@MainActor
struct SimulatorDeviceStateMonitorTests {
    @Test("Registration retains its numeric handle and unregisters it")
    func numericRegistrationHandle() throws {
        let manager = DeviceStateNotificationManagerDouble()
        let device = DeviceStateNotificationDeviceDouble(manager: manager)

        let monitor = try SimulatorDeviceStateMonitor(device: device) {}
        monitor.invalidate()

        #expect(manager.unregisteredHandle == manager.registrationHandle)
    }
}
