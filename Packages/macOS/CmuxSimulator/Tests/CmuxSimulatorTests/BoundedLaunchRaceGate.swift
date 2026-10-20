import Foundation

final class BoundedLaunchRaceGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var released = false

    func pause() {
        condition.lock()
        paused = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilPaused() {
        condition.lock()
        while !paused { condition.wait() }
        condition.unlock()
    }

    func resume() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
