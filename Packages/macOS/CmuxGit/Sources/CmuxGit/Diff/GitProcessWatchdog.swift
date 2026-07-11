import Darwin
import Foundation

/// Enforces a hard return bound for one git subprocess. Closing the reader
/// unblocks the synchronous pipe drain even when a descendant inherited the
/// descriptor, and SIGKILL escalation handles a child that ignores SIGTERM.
final class GitProcessWatchdog: @unchecked Sendable {
    private static let sigkillGraceSeconds = 0.2
    private static let timerQueue = DispatchQueue(label: "com.cmuxterm.CmuxGit.process-watchdog")

    private let lock = NSLock()
    private var fired = false
    private let process: Process
    private let processGroupIdentifier: pid_t
    private let outputHandle: FileHandle

    init(process: Process, processGroupIdentifier: pid_t, outputHandle: FileHandle) {
        self.process = process
        self.processGroupIdentifier = processGroupIdentifier
        self.outputHandle = outputHandle
    }

    func fire() {
        let shouldTerminate = lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
        guard shouldTerminate else { return }
        try? outputHandle.close()
        guard process.isRunning else { return }
        if kill(-processGroupIdentifier, SIGTERM) != 0 {
            process.terminate()
        }
        scheduleSigkill()
    }

    var didFire: Bool {
        lock.withLock { fired }
    }

    private func scheduleSigkill() {
        let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
        timer.schedule(deadline: .now() + Self.sigkillGraceSeconds)
        timer.setEventHandler { [process, processGroupIdentifier] in
            kill(-processGroupIdentifier, SIGKILL)
            if process.isRunning {
                process.terminate()
            }
            timer.cancel()
        }
        timer.resume()
    }
}
