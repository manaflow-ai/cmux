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
    private let outputHandle: FileHandle

    init(process: Process, outputHandle: FileHandle) {
        self.process = process
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
        process.terminate()
        scheduleSigkill()
    }

    var didFire: Bool {
        lock.withLock { fired }
    }

    private func scheduleSigkill() {
        let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
        timer.schedule(deadline: .now() + Self.sigkillGraceSeconds)
        timer.setEventHandler { [process] in
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            timer.cancel()
        }
        timer.resume()
    }
}
