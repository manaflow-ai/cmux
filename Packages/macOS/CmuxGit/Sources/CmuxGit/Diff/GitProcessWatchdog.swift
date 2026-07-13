import Darwin
import Foundation

/// Enforces a hard return bound for one git process group. SIGKILL escalation
/// handles a descendant that ignores SIGTERM, then closing the reader unblocks
/// the synchronous pipe drain even after the supervising shell has exited.
final class GitProcessWatchdog: @unchecked Sendable {
    private static let sigkillGraceSeconds = 0.2
    private static let timerQueue = DispatchQueue(label: "com.cmuxterm.CmuxGit.process-watchdog")

    private let lock = NSLock()
    private var fired = false
    private var completed = false
    private var escalationGeneration = 0
    private var escalationTimer: (any DispatchSourceTimer)?
    private let process: Process
    private let processGroupIdentifier: pid_t
    private let outputHandle: FileHandle

    init(process: Process, processGroupIdentifier: pid_t, outputHandle: FileHandle) {
        self.process = process
        self.processGroupIdentifier = processGroupIdentifier
        self.outputHandle = outputHandle
    }

    func fire() {
        let groupSignalFailed: Bool? = lock.withLock {
            guard !fired, !completed else { return nil }
            fired = true
            scheduleSigkillLocked()
            // Completion and the first signal share one critical section, so
            // a reaped process group can never be signalled after cancellation.
            return kill(-processGroupIdentifier, SIGTERM) != 0
        }
        guard let groupSignalFailed else { return }
        if groupSignalFailed {
            cancelEscalation()
            try? outputHandle.close()
            if process.isRunning {
                process.terminate()
            }
        }
    }

    var didFire: Bool {
        lock.withLock { fired }
    }

    /// Invalidates a pending SIGKILL as soon as the wrapper has reaped git.
    /// Without this cancellation, a delayed signal could target an unrelated
    /// process group that reused git's numeric identifier after exit.
    func cancelEscalation() {
        let timer = lock.withLock {
            completed = true
            escalationGeneration &+= 1
            let timer = escalationTimer
            escalationTimer = nil
            return timer
        }
        timer?.setEventHandler {}
        timer?.cancel()
    }

    /// Schedules escalation while the caller owns `lock`.
    private func scheduleSigkillLocked() {
        escalationGeneration &+= 1
        let generation = escalationGeneration
        let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
        escalationTimer = timer
        timer.schedule(deadline: .now() + Self.sigkillGraceSeconds)
        timer.setEventHandler { [weak self] in
            defer { timer.cancel() }
            guard let self else { return }
            self.lock.withLock {
                guard !self.completed,
                      self.escalationGeneration == generation else { return }
                // Keep the generation check and signal atomic with respect
                // to cancellation after `waitUntilExit`.
                let groupSignalFailed = kill(-self.processGroupIdentifier, SIGKILL) != 0
                if groupSignalFailed, self.process.isRunning {
                    self.process.terminate()
                }
                try? self.outputHandle.close()
                self.escalationTimer = nil
            }
        }
        timer.resume()
    }
}
