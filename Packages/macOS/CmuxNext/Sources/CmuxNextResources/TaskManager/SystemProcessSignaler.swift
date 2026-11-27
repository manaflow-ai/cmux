import Darwin
import Foundation

/// ``ProcessSignaling`` with `kill(2)`: SIGTERM, which a process may handle
/// to save its work, as Activity Monitor's Quit does.
public struct SystemProcessSignaler: ProcessSignaling {
    public init() {}

    public func terminate(_ pid: Int32) -> Bool {
        pid > 1 && kill(pid, SIGTERM) == 0
    }
}
