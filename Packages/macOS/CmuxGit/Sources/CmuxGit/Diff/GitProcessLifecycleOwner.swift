import Darwin
import Foundation
import os

struct GitProcessLifecyclePermit: Hashable, Sendable {
    fileprivate let identifier: UInt64
}

struct GitProcessLifecycleState: Sendable {
    let maxProcesses: Int
    private var nextPermitIdentifier: UInt64 = 0
    private var activePermits: Set<GitProcessLifecyclePermit> = []
    private var reapingProcesses: [GitProcessLifecyclePermit: pid_t] = [:]

    var reapingProcessCount: Int { reapingProcesses.count }

    init(maxProcesses: Int) {
        self.maxProcesses = maxProcesses
    }

    mutating func beginProcess() -> GitProcessLifecyclePermit? {
        guard reapingProcesses.isEmpty,
              activePermits.count < maxProcesses else { return nil }
        nextPermitIdentifier &+= 1
        let permit = GitProcessLifecyclePermit(identifier: nextPermitIdentifier)
        activePermits.insert(permit)
        return permit
    }

    mutating func finishProcess(_ permit: GitProcessLifecyclePermit) {
        activePermits.remove(permit)
    }

    mutating func transferToReaper(
        _ permit: GitProcessLifecyclePermit,
        processIdentifier: pid_t
    ) -> Bool {
        guard activePermits.remove(permit) != nil else { return false }
        reapingProcesses[permit] = processIdentifier
        return true
    }

    mutating func didReap(_ permit: GitProcessLifecyclePermit) {
        reapingProcesses.removeValue(forKey: permit)
    }
}

/// Process-wide admission and detached-reap ownership for Git subprocesses.
/// The lock only protects a bounded set of lifecycle identifiers; waits and
/// process I/O always happen outside the critical section.
final class GitProcessLifecycleOwner: @unchecked Sendable {
    static let shared = GitProcessLifecycleOwner()

    private let state: OSAllocatedUnfairLock<GitProcessLifecycleState>

    init(maxProcesses: Int = 8) {
        precondition(maxProcesses > 0)
        state = OSAllocatedUnfairLock(
            initialState: GitProcessLifecycleState(maxProcesses: maxProcesses)
        )
    }

    func beginProcess() -> GitProcessLifecyclePermit? {
        state.withLock { $0.beginProcess() }
    }

    func finishProcess(_ permit: GitProcessLifecyclePermit) {
        state.withLock { $0.finishProcess(permit) }
    }

    func transferToDetachedReaper(
        _ permit: GitProcessLifecyclePermit,
        processIdentifier: pid_t
    ) {
        let didTransfer = state.withLock {
            $0.transferToReaper(permit, processIdentifier: processIdentifier)
        }
        guard didTransfer else { return }
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(processIdentifier, &status, 0) < 0, errno == EINTR {}
            state.withLock { $0.didReap(permit) }
        }
    }
}
