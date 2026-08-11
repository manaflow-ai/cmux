internal import Foundation

@MainActor
final class BackendOnlyWindowMouseMovedEventsState: NSObject {
    let originalValue: Bool
    var leaseCount = 0

    init(originalValue: Bool) {
        self.originalValue = originalValue
    }
}
