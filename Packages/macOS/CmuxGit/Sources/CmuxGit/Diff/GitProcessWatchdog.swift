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
        let shouldTerminate = lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
        guard shouldTerminate else { return }
        try? outputHandle.close()
        guard process.isRunning else { return }
        scheduleSigkill()
        if kill(-processGroupIdentifier, SIGTERM) != 0 {
            process.terminate()
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

    private func scheduleSigkill() {
        lock.withLock {
            guard !completed else { return }
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
                          self.escalationGeneration == generation,
                          self.process.isRunning else { return }
                    // Keep the generation check and signal atomic with respect
                    // to cancellation after `waitUntilExit`.
                    kill(-self.processGroupIdentifier, SIGKILL)
                    if self.process.isRunning {
                        self.process.terminate()
                    }
                    self.escalationTimer = nil
                }
            }
            timer.resume()
        }
    }
}
