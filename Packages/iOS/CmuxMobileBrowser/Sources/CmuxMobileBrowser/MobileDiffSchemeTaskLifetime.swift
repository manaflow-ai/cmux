import Foundation

/// Keeps WebKit scheme-task callbacks from outliving a synchronous `stop` call.
///
/// WebKit may stop a request while its payload is being loaded asynchronously.
/// The protocol's synchronous stop boundary cannot await an actor, so one
/// condition protects task membership and callback counts. Removing the task and
/// waiting for callbacks already in flight guarantees no callback can begin after
/// `stop(_:)` returns.
final class MobileDiffSchemeTaskLifetime: @unchecked Sendable {
    private let condition = NSCondition()
    private var activeTasks: Set<ObjectIdentifier> = []
    private var callbacksInFlight: [ObjectIdentifier: Int] = [:]

    func register(_ taskID: ObjectIdentifier) {
        condition.lock()
        activeTasks.insert(taskID)
        callbacksInFlight[taskID] = 0
        condition.unlock()
    }

    func performCallback(_ taskID: ObjectIdentifier, _ callback: () -> Void) -> Bool {
        condition.lock()
        guard activeTasks.contains(taskID) else {
            condition.unlock()
            return false
        }
        callbacksInFlight[taskID, default: 0] += 1
        condition.unlock()

        callback()

        condition.lock()
        callbacksInFlight[taskID, default: 1] -= 1
        if callbacksInFlight[taskID] == 0 {
            condition.broadcast()
        }
        let isActive = activeTasks.contains(taskID)
        condition.unlock()
        return isActive
    }

    func finish(_ taskID: ObjectIdentifier) {
        stop(taskID)
    }

    func stop(_ taskID: ObjectIdentifier) {
        condition.lock()
        guard activeTasks.remove(taskID) != nil else {
            condition.unlock()
            return
        }
        while callbacksInFlight[taskID, default: 0] > 0 {
            condition.wait()
        }
        callbacksInFlight[taskID] = nil
        condition.unlock()
    }
}
