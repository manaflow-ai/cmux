import Foundation
import ObjectiveC.runtime

/// Retains CoreSimulator's per-device notification token and translates each
/// notification into one main-actor state read.
@MainActor
final class SimulatorDeviceStateMonitor {
    private var token: NSObject?

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
        let selector = NSSelectorFromString("registerNotificationHandlerOnQueue:handler:")
        guard manager.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: manager), selector)
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
        ) -> AnyObject?
        guard let token = unsafeBitCast(implementation, to: Function.self)(
            manager,
            selector,
            DispatchQueue.main,
            handler as AnyObject
        ) as? NSObject else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "CoreSimulator rejected device-state notification registration."
            )
        }
        self.token = token
    }

    func invalidate() {
        guard let token else { return }
        self.token = nil
        let selector = NSSelectorFromString("invalidate")
        if token.responds(to: selector) {
            token.perform(selector)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            invalidate()
        }
    }
}
