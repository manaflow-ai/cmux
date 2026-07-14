import Darwin
import Foundation

/// Enforces a hard return bound for one git process group. SIGKILL escalation
/// handles a descendant that ignores SIGTERM, then closing the reader unblocks
/// the synchronous pipe drain even after the supervising shell has exited.
/// Concurrent callbacks touch only `lifecycle`, whose storage is accessed with
/// barriered compare-and-swap operations supported by the macOS 14 target.
final class GitProcessWatchdog: @unchecked Sendable {
    private static let sigkillGraceSeconds = 0.2
    private static let timerQueue = DispatchQueue(
        label: "com.cmuxterm.CmuxGit.process-watchdog",
        qos: .userInitiated
    )

    private let lifecycle: UnsafeMutablePointer<Int32>
    private let process: Process
    private let processGroupIdentifier: pid_t
    private let outputHandle: FileHandle

    init(process: Process, processGroupIdentifier: pid_t, outputHandle: FileHandle) {
        lifecycle = .allocate(capacity: 1)
        lifecycle.initialize(to: GitProcessWatchdogLifecycle.idle.rawValue)
        self.process = process
        self.processGroupIdentifier = processGroupIdentifier
        self.outputHandle = outputHandle
    }

    deinit {
        lifecycle.deinitialize(count: 1)
        lifecycle.deallocate()
    }

    func fire() {
        let claimed = transition(from: .idle, to: .terminating)
        guard claimed else { return }
        let groupSignalFailed = kill(-processGroupIdentifier, SIGTERM) != 0
        if groupSignalFailed {
            _ = transition(from: .terminating, to: .completedAfterFire)
            try? outputHandle.close()
            if process.isRunning {
                process.terminate()
            }
            return
        }
        _ = transition(from: .terminating, to: .armed)
        scheduleSigkill()
    }

    var didFire: Bool {
        switch currentLifecycle {
        case .idle, .completedWithoutFire, nil:
            return false
        case .terminating, .armed, .escalating, .completedAfterFire, .escalated:
            return true
        }
    }

    /// Invalidates a pending SIGKILL as soon as the wrapper has reaped git.
    /// Without this cancellation, a delayed signal could target an unrelated
    /// process group that reused git's numeric identifier after exit.
    func cancelEscalation() {
        while true {
            let current = currentLifecycle ?? .idle
            switch current {
            case .idle:
                if transition(from: current, to: .completedWithoutFire) { return }
            case .armed:
                if transition(from: current, to: .completedAfterFire) { return }
            case .terminating, .escalating:
                // The signal syscall is bounded. Waiting for its state publish
                // prevents returning while a reaped process-group ID could be reused.
                sched_yield()
            case .completedWithoutFire, .completedAfterFire, .escalated:
                return
            }
        }
    }

    private func scheduleSigkill() {
        let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
        timer.schedule(deadline: .now() + Self.sigkillGraceSeconds)
        timer.setEventHandler { [weak self] in
            defer { timer.cancel() }
            self?.escalate()
        }
        timer.resume()
    }

    private func escalate() {
        let claimed = transition(from: .armed, to: .escalating)
        guard claimed else { return }
        let groupSignalFailed = kill(-processGroupIdentifier, SIGKILL) != 0
        if groupSignalFailed, process.isRunning {
            process.terminate()
        }
        try? outputHandle.close()
        _ = transition(from: .escalating, to: .escalated)
    }

    private var currentLifecycle: GitProcessWatchdogLifecycle? {
        GitProcessWatchdogLifecycle(rawValue: OSAtomicAdd32Barrier(0, lifecycle))
    }

    private func transition(
        from expected: GitProcessWatchdogLifecycle,
        to desired: GitProcessWatchdogLifecycle
    ) -> Bool {
        OSAtomicCompareAndSwap32Barrier(expected.rawValue, desired.rawValue, lifecycle)
    }
}
