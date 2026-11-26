#if canImport(Darwin)
package import Darwin
import Foundation
import os

/// How many file descriptors this process holds open, and how many of them are pipes: its own
/// `/dev/fd` listed once, a few microseconds for a few hundred descriptors.
///
/// NIGHTLY held about 2,000 open pipes, 452 of them full at 64 KB, when its main thread waited
/// 391 s in a pipe write (2026-11-09, cmuxterm-hq#8747): the kernel's pipe memory was used up and
/// nothing had watched the count. Hang and stall reports carry it now, and ``noteBudget(_:)`` logs
/// a fault while the pipe count is over ``pipeBudget`` (never refusing anything).
package struct OpenDescriptors: Sendable, Equatable {
    /// Every open descriptor.
    package var total: Int
    /// The pipes among them (`S_IFIFO`).
    package var pipes: Int

    package init(total: Int, pipes: Int) {
        self.total = total
        self.pipes = pipes
    }

    /// This process's count now; nil when `/dev/fd` cannot be listed. Reads this process's own
    /// descriptor table only (`/dev/fd`, one `fstat` each): no other process is looked at.
    package static func current() -> OpenDescriptors? {
        guard let directory = opendir("/dev/fd") else { return nil }
        defer { closedir(directory) }
        // The listing's own descriptor is not counted.
        let own = dirfd(directory)
        var total = 0, pipes = 0
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            guard let fd = Int32(name), fd != own else { continue }
            var info = stat()
            guard fstat(fd, &info) == 0 else { continue }
            total += 1
            if info.st_mode & S_IFMT == S_IFIFO { pipes += 1 }
        }
        return OpenDescriptors(total: total, pipes: pipes)
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
#endif
