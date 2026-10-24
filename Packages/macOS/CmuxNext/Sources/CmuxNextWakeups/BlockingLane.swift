/// The kind of blocking work a ``BackgroundWork`` lane runs, as Chrome's `MayBlock` trait plus a kind.
///
/// Swift's cooperative pool has one thread per core: one blocking call there stalls every task queued
/// behind it, and a few of them stall the whole app's async work while a person types. Work that may block
/// therefore never runs on the pool; it runs on the lane of its kind, so a slow disk never delays a DNS
/// lookup and a long parse never delays a file read.
public enum BlockingLane: Int, Sendable, CaseIterable, CustomStringConvertible {
    /// Disk I/O: file reads and writes, directory listings, file-backed JSON or plist loads and saves.
    /// Serial per ``WorkPriority``: at most one item of each priority at a time.
    case files
    /// Synchronous system calls that wait on something outside the process: `getaddrinfo`, Security,
    /// Launch Services, AX. Concurrent up to ``BackgroundWork/systemWidth`` items, highest priority first:
    /// such a call can hang for its own timeout, and one hung call must not hold every later one.
    case system
    /// CPU-bound work too long for the pool (a big parse, an index build): it does not block, but it
    /// must not fill the pool. Concurrent up to ``BackgroundWork/cpuWidth`` items, highest priority first.
    case cpu

    public var description: String {
        switch self {
        case .files: "files"
        case .system: "system"
        case .cpu: "cpu"
        }
    }
}
