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

@objcMembers
private final class DeviceStateNotificationDeviceDouble: NSObject {
    let notificationManager: NSObject

    init(manager: NSObject) {
        notificationManager = manager
    }
}

@objcMembers
private final class DeviceStateNotificationManagerDouble: NSObject {
    let registrationHandle: UInt64 = 2
    private(set) var unregisteredHandle: UInt64?

    @objc(registerNotificationHandlerOnQueue:handler:)
    func registerNotificationHandler(
        on queue: DispatchQueue,
        handler: @escaping (NSDictionary) -> Void
    ) -> UInt64 {
        registrationHandle
    }

    @objc(unregisterNotificationHandler:error:)
    func unregisterNotificationHandler(
        _ handle: UInt64,
        error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        unregisteredHandle = handle
        return true
    }
}
