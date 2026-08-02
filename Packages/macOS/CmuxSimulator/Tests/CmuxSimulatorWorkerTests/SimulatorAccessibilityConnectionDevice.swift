import Foundation

final class SimulatorAccessibilityConnectionDevice: NSObject {
    @objc dynamic var accessibilityConnection: NSObject?

    @objc(sendAccessibilityRequestAsync:completionQueue:completionHandler:)
    dynamic func sendAccessibilityRequestAsync(
        _ request: AnyObject,
        completionQueue: DispatchQueue,
        completionHandler: @escaping (AnyObject?) -> Void
    ) {
        _ = request
        _ = completionQueue
        _ = completionHandler
    }
}
