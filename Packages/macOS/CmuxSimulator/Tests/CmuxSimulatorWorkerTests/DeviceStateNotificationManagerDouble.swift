import Foundation

@objcMembers
final class DeviceStateNotificationManagerDouble: NSObject {
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
