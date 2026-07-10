import Foundation

// Process and pipe handles are touched from MainActor; the termination inbox synchronizes callback delivery.
final class CuaDriverProcessSession: @unchecked Sendable {
    let process: Process
    let stdin: Pipe
    let terminationInbox = CuaDriverTerminationInbox()
    var stdoutDrainTask: Task<Void, Never>?
    var stderrDrainTask: Task<Void, Never>?
    var pid: Int32?
    var isStopping = false
    var suppressTerminationFailureBeforeHandshake: Bool

    init(
        process: Process,
        stdin: Pipe,
        stdoutDrainTask: Task<Void, Never>?,
        stderrDrainTask: Task<Void, Never>?,
        suppressTerminationFailureBeforeHandshake: Bool = false
    ) {
        self.process = process
        self.stdin = stdin
        self.stdoutDrainTask = stdoutDrainTask
        self.stderrDrainTask = stderrDrainTask
        self.suppressTerminationFailureBeforeHandshake = suppressTerminationFailureBeforeHandshake
    }

    deinit {
        stdoutDrainTask?.cancel()
        stderrDrainTask?.cancel()
    }
}
