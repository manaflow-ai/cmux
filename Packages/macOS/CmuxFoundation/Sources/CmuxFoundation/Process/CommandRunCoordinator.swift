internal import Foundation

/// Actor-isolated completion state for one command invocation.
actor CommandRunCoordinator {
    typealias Completion = (
        result: CommandResult,
        timer: CommandTimer?,
        exitSource: CommandProcessExitSource?,
        reapProcess: (@Sendable () -> Void)?
    )

    typealias ImmediateClaim = (
        won: Bool,
        timer: CommandTimer?,
        exitSource: CommandProcessExitSource?
    )

    private var stdout: Data?
    private var stderr: Data?
    private var didTerminate = false
    private var exitStatus: Int32?
    private var resumed = false
    private var deadlineTimer: CommandTimer?
    private var processExitSource: CommandProcessExitSource?
    private var processReapAction: (@Sendable () -> Void)?

    func recordStdout(_ data: Data) -> Completion? {
        stdout = data
        return completionIfReady()
    }

    func recordStderr(_ data: Data) -> Completion? {
        stderr = data
        return completionIfReady()
    }

    func recordExit(status: Int32) -> Completion? {
        didTerminate = true
        exitStatus = status
        return completionIfReady()
    }

    func claimImmediate() -> ImmediateClaim {
        guard !resumed else { return (false, nil, nil) }
        resumed = true
        let timer = deadlineTimer
        deadlineTimer = nil
        let exitSource = processExitSource
        processExitSource = nil
        processReapAction = nil
        return (true, timer, exitSource)
    }

    func installDeadlineTimer(_ timer: CommandTimer) -> Bool {
        guard !resumed else { return false }
        deadlineTimer = timer
        return true
    }

    func installExitSource(
        _ source: CommandProcessExitSource,
        reapProcess: @escaping @Sendable () -> Void
    ) -> Bool {
        guard !resumed else { return false }
        processExitSource = source
        processReapAction = reapProcess
        return true
    }

    private func completionIfReady() -> Completion? {
        guard !resumed,
              let stdout,
              let stderr,
              didTerminate else {
            return nil
        }
        resumed = true
        let timer = deadlineTimer
        deadlineTimer = nil
        let exitSource = processExitSource
        processExitSource = nil
        let reapProcess = processReapAction
        processReapAction = nil
        return (
            CommandResult(
                stdout: String(data: stdout, encoding: .utf8),
                stderr: String(data: stderr, encoding: .utf8),
                exitStatus: exitStatus,
                timedOut: false,
                executionError: nil
            ),
            timer,
            exitSource,
            reapProcess
        )
    }
}
