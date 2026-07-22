import Darwin
import Foundation
import os

/// Coordinates synchronous `Process` launch and cancellation callbacks.
// Safety: the Process reference is immutable and every cross-task launch/cancel
// phase transition is guarded by one short lock; an actor would add a Task hop
// from the synchronous cancellation callback and leave a launch race.
final class ArtifactGitProcessCancellation: @unchecked Sendable {
    private enum Phase: Sendable {
        case pending
        case launching
        case launched
        case cancelled
    }

    private let process: Process
    private let phase = OSAllocatedUnfairLock(initialState: Phase.pending)

    init(process: Process) {
        self.process = process
    }

    func beginLaunch() -> Bool {
        phase.withLock { phase in
            guard phase == .pending else { return false }
            phase = .launching
            return true
        }
    }

    func didLaunch() {
        let shouldTerminate = phase.withLock { phase in
            if phase == .cancelled { return true }
            phase = .launched
            return false
        }
        if shouldTerminate, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func cancel() {
        let shouldTerminate = phase.withLock { phase in
            switch phase {
            case .cancelled:
                return false
            case .pending:
                phase = .cancelled
                return false
            case .launching, .launched:
                phase = .cancelled
                return true
            }
        }
        if shouldTerminate, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
