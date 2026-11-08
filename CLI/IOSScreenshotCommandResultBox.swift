import CmuxSimulator
import Foundation

// SAFETY: `lock` protects the sole result slot shared by the detached command
// task and the synchronous CLI thread, and the stored result is Sendable.
final class IOSScreenshotCommandResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: SimulatorOwnedCommandResult?

    func set(_ result: SimulatorOwnedCommandResult) {
        lock.withLock { self.result = result }
    }

    func get() -> SimulatorOwnedCommandResult? {
        lock.withLock { result }
    }
}
