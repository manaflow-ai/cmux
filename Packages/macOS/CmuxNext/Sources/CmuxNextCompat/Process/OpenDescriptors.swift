package import Darwin
import Foundation
import os

/// How many file descriptors this process holds open, and how many of them are pipes: one
/// `proc_pidinfo(PROC_PIDLISTFDS)` call, no file system access, a few microseconds.
///
/// NIGHTLY held about 2,000 open pipes, 452 of them full at 64 KB, when its main thread waited
/// 391 s in a pipe write (2026-11-09, cmuxterm-hq#8747): the kernel's pipe memory was used up and
/// nothing had watched the count. Hang and stall reports carry it now, and ``noteBudget(_:)`` logs
/// a fault while the pipe count is over ``pipeBudget`` (never refusing anything).
package struct OpenDescriptors: Sendable, Equatable {
    /// Every open descriptor.
    package var total: Int
    /// The pipes among them (`PROX_FDTYPE_PIPE`).
    package var pipes: Int

    package init(total: Int, pipes: Int) {
        self.total = total
        self.pipes = pipes
    }

    /// This process's count now; nil when the kernel does not answer.
    package static func current() -> OpenDescriptors? {
        let pid = getpid()
        // The size the kernel needs for every descriptor this process has now.
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for descriptors opened between the two calls.
        let capacity = Int(needed) / stride + 64
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let written = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else { return nil }
        let count = min(Int(written) / stride, capacity)
        var pipes = 0
        for index in 0..<count where fds[index].proc_fdtype == UInt32(PROX_FDTYPE_PIPE) { pipes += 1 }
        return OpenDescriptors(total: count, pipes: pipes)
    }

    /// The pipe count past which ``noteBudget(_:)`` logs a fault. A healthy app holds a few dozen
    /// (each live helper child two or three); 2,000 was the leak.
    package static let pipeBudget = 1_000
    /// The descriptor count past which ``noteBudget(_:)`` logs a fault.
    package static let totalBudget = 4_000

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "descriptors")

    /// Logs a fault when `count` (``current()`` by default) passes a budget. Returns whether it is
    /// over. Never refuses anything: the count is what a leak hunt needs. No state of its own (no
    /// process-wide lock or flag): a leaking app logs one fault per child launch, which is the trail
    /// a leak hunt reads.
    @discardableResult
    package static func noteBudget(_ count: OpenDescriptors? = current()) -> Bool {
        guard let count else { return false }
        let isOver = count.pipes > pipeBudget || count.total > totalBudget
        if isOver {
            log.fault("open descriptors over budget: \(count.total) open, \(count.pipes) pipes (budget \(totalBudget) and \(pipeBudget) pipes)")
        }
        return isOver
    }

    /// ``noteBudget(_:)`` on the shared utility queue, never the caller's thread: each child launch
    /// calls this, so a leak shows up in the log the moment it passes the bound.
    package static func noteBudgetSoon() {
        DispatchQueue.global(qos: .utility).async { noteBudget() }
    }
}
