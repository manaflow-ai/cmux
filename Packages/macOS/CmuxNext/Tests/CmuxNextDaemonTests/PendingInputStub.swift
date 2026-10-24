import CmuxNextWakeups
import Foundation

/// A person's input the test turns on and off (``InputPendingSource``).
@MainActor
final class PendingInputStub: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}
