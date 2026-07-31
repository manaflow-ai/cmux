import Foundation
import ObjectiveC.runtime

/// Retains CoreSimulator's per-device notification handle and translates each
/// notification into one main-actor state read.
@MainActor
final class SimulatorDeviceStateMonitor {
    private var manager: NSObject?
    private var registrationHandle: UInt64?

    init(
        device: NSObject,
        onStateChange: @escaping @MainActor () -> Void
    ) throws {
        guard let manager = objectProperty(device, selectorName: "notificationManager") as? NSObject
        else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "CoreSimulator did not expose device-state notifications."
            )
        }
        let registerSelector = NSSelectorFromString("registerNotificationHandlerOnQueue:handler:")
        let unregisterSelector = NSSelectorFromString("unregisterNotificationHandler:error:")
        guard manager.responds(to: registerSelector),
              manager.responds(to: unregisterSelector),
              let implementation = class_getMethodImplementation(type(of: manager), registerSelector)
        else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "CoreSimulator device-state notification registration is unavailable."
            )
        }

        let handler: @convention(block) (AnyObject) -> Void = { @MainActor _ in
            onStateChange()
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            AnyObject
        ) -> UInt64
        let registrationHandle = unsafeBitCast(implementation, to: Function.self)(
            manager,
            registerSelector,
            DispatchQueue.main,
            handler as AnyObject
        )
        self.manager = manager
        self.registrationHandle = registrationHandle
    }

    func invalidate() {
        guard let manager, let registrationHandle else { return }
        self.manager = nil
        self.registrationHandle = nil
        let selector = NSSelectorFromString("unregisterNotificationHandler:error:")
        guard manager.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: manager), selector)
        else { return }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            UInt64,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> Bool
        var error: NSError?
        _ = unsafeBitCast(implementation, to: Function.self)(
            manager,
            selector,
            registrationHandle,
            &error
        )
    }

    deinit {
        MainActor.assumeIsolated {
            invalidate()
        }
    }
}
