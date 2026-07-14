import Darwin
import Foundation

/// Injected process admission and detached-reap ownership for Git subprocesses.
/// A single atomic word tracks active and reaping counts at this synchronous
/// POSIX boundary; waits and process I/O never occupy an actor or critical
/// section.
public final class GitProcessLifecycleService: @unchecked Sendable {
    private let maxProcesses: Int
    // Safety: the low 32 bits are the active count and the high 32 bits are
    // the reaping count. Every access uses OSAtomic operations.
    private nonisolated(unsafe) var processCounts: Int64 = 0

    /// Creates a lifecycle service with a bound on concurrent Git processes.
    ///
    /// - Parameter maxProcesses: Maximum active processes before admission
    ///   fails closed. Detached reapers block new admission until they finish.
    public init(maxProcesses: Int = 8) {
        precondition(maxProcesses > 0)
        self.maxProcesses = maxProcesses
    }

    func beginProcess() -> GitProcessLifecyclePermit? {
        guard updateCounts({ counts in
            let active = Int(counts & 0xffff_ffff)
            let reaping = Int(counts >> 32)
            guard reaping == 0, active < maxProcesses else { return nil }
            return counts + 1
        }) else { return nil }
        return GitProcessLifecyclePermit()
    }

    func finishProcess(_ permit: GitProcessLifecyclePermit) {
        guard permit.finishActive() else { return }
        precondition(updateCounts { counts in
            guard counts & 0xffff_ffff > 0 else { return nil }
            return counts - 1
        })
    }

    func transferToDetachedReaper(
        _ permit: GitProcessLifecyclePermit,
        processIdentifier: pid_t
    ) {
        guard permit.transferToReaper() else { return }
        precondition(updateCounts { counts in
            guard counts & 0xffff_ffff > 0 else { return nil }
            return counts - 1 + (1 << 32)
        })
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(processIdentifier, &status, 0) < 0, errno == EINTR {}
            guard permit.finishReaping() else { return }
            precondition(updateCounts { counts in
                guard counts >> 32 > 0 else { return nil }
                return counts - (1 << 32)
            })
        }
    }

    private func updateCounts(_ transform: (UInt64) -> UInt64?) -> Bool {
        while true {
            let current = OSAtomicAdd64Barrier(0, &processCounts)
            let counts = UInt64(bitPattern: current)
            guard let updated = transform(counts) else { return false }
            if OSAtomicCompareAndSwap64Barrier(
                current,
                Int64(bitPattern: updated),
                &processCounts
            ) {
                return true
            }
        }
    }
}
