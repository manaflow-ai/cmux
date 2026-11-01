import CmuxNextCompat
import Darwin
import Dispatch
import Foundation

/// The process that posted a key or mouse event (`kCGEventSourceUnixProcessID`), as
/// ``EventSourceProcesses`` read it.
nonisolated struct EventSourceProcess: Equatable, Sendable {
    /// When the process started, in microseconds since 1970 (`kinfo_proc.kp_proc.p_starttime`):
    /// with the pid, it names one process, so a pid the kernel gives to a new process is a new one.
    var start: UInt64
    /// Its executable (`proc_pidpath`).
    var path: String
}

/// The executable path of each process that posts key and mouse events to the app, by pid, for
/// ``AgentPanePersonInput`` and ``PersonInputCheck``.
///
/// The key path makes no system call (P-MAIN S5): ``path(of:)`` reads this table under its lock and
/// nothing else. A pid not in the table yet answers nil (the checks' safe default: not the person's)
/// at once, and its process is read on this table's own queue: the start time and the path, once per
/// process. The person's own input (the HID system, pid 0) never reaches the table.
///
/// Both reads have no same-user check (`sysctl(KERN_PROC_PID)` and `proc_pidpath`), so the processes
/// another user owns (the WindowServer, launchd, the root Screen Sharing daemon) are read as this user.
/// A live process the table still cannot read keeps the safe default until its exit watch fires: it is
/// not read again (with a new kernel watch) for each of its events.
///
/// A pid the kernel gives to a new process: each entry is one process (pid and start time), and an
/// exit watch on its pid, armed before the read, removes it when that process ends. The watch runs on
/// the same serial queue as the read, so an exit always comes after the entry it removes. A pid is
/// given again only after its process has ended and been reaped and the kernel's pid counter has come
/// round to it, so the next event from that pid misses and is read again.
///
/// An exec (same pid and start time, a new program) fires the same watch: the entry leaves, and the next
/// event reads the new image.
///
/// SECURITY: an entry exists only while its exit watch is attached. When the kernel refuses the watch
/// (any errno from `EVFILT_PROC`/`NOTE_EXIT`), nothing is kept: the event takes the safe default (not
/// the person's) and the next event from that pid is read again, off the main thread. So an old
/// verdict can never outlive its process, and a reused pid never inherits it.
///
/// Bound: one entry and one kernel exit watch per live process that posted an event to the app; each
/// leaves with its process (R9: no constant cap; the bound is the live processes).
///
/// One table per app, built in the composition root (`AppServices.personInput.sources`) and passed through `init`;
/// tests build their own.
public nonisolated final class EventSourceProcesses: Sendable {
    /// Reads the process `pid` names now; nil when there is none. A system call: never on the main thread.
    typealias Resolve = @Sendable (pid_t) -> EventSourceProcess?
    /// Arms a watch for the exit of process `pid`: `exited` runs on `queue` once that process ends or runs
    /// a new program (exec: same pid and start time, a new image, so the path read is no longer its).
    /// Returns the watch's cancel, or nil when the kernel did not attach it (the process is gone, or
    /// the watch is refused): then nothing may be kept for that pid.
    typealias WatchExit = @Sendable (pid_t, DispatchQueue, @escaping @Sendable () -> Void) -> (@Sendable () -> Void)?

    /// This process's pid, read once.
    static let ownPID = getpid()

    private let resolve: Resolve
    private let watchExit: WatchExit
    private let queue: DispatchQueue
    private let state = Mutex(State())

    private nonisolated struct State {
        var entries: [pid_t: Entry] = [:]
        var nextWatch: UInt64 = 0
    }

    private nonisolated enum Entry {
        /// Read on the queue now; events meanwhile take the safe default and post no second read.
        case reading
        /// The process the pid names until `watch` (its exit watch) removes it.
        case read(EventSourceProcess, watch: UInt64, cancel: @Sendable () -> Void)
        /// A live process the read could not name: the safe default, with no new read, until `watch`
        /// (its exit watch) removes it.
        case unreadable(watch: UInt64, cancel: @Sendable () -> Void)
    }

    /// The app's table: the kernel's answers, read on its own queue.
    public convenience init() {
        self.init(resolve: Self.system, watchExit: Self.kernelExit,
                  queue: DispatchQueue(label: "com.cmuxterm.next.event-source-processes", qos: .userInitiated))
    }

    /// A table with its own reads and exit watches (tests). `queue` must be serial: the reads and the
    /// exits are ordered on it.
    init(resolve: @escaping Resolve, watchExit: @escaping WatchExit, queue: DispatchQueue) {
        self.resolve = resolve
        self.watchExit = watchExit
        self.queue = queue
    }

    /// The executable path of the process `pid` names, from the table only; nil when it is not read
    /// yet (the read is then posted to the queue, once) or names no process. No system call, no wait.
    func path(of pid: pid_t) -> String? { // perf-hot: 1us key-dispatch (every key- and mouse-down a process posts)
        let (path, post): (String?, Bool) = state.withLock { state in
            switch state.entries[pid] {
            case let .read(process, _, _): return (process.path, false)
            case .reading, .unreadable: return (nil, false)
            case nil:
                state.entries[pid] = .reading
                return (nil, true)
            }
        }
        if post { queue.async { self.read(pid) } }
        return path
    }

    /// The process the table holds for `pid` (tests and logs).
    func cached(_ pid: pid_t) -> EventSourceProcess? {
        state.withLock { state in
            guard case let .read(process, _, _) = state.entries[pid] else { return nil }
            return process
        }
    }

    /// Queues a read of process `pid` when the table does not hold it, and returns at once (no system
    /// call): any event a process posts (a mouse move, a scroll) fills the table before its first click.
    func prime(_ pid: pid_t) { // perf-hot: 1us key-dispatch (every mouse move, scroll and modifier change a process posts)
        _ = path(of: pid)
    }

    /// Returns once every read and exit queued before the call has been applied (tests).
    func settled() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    /// On the queue: arms the exit watch, then reads the process. Armed first, so the exit of the
    /// process read here (or of an earlier one with this pid) runs after this item and removes the entry.
    /// No watch, no entry (SECURITY, see the type).
    private func read(_ pid: pid_t) {
        let watch = state.withLock { state in
            state.nextWatch &+= 1
            return state.nextWatch
        }
        guard let cancel = watchExit(pid, queue, { [weak self] in self?.exited(pid, watch: watch) }) else {
            state.withLock { _ = $0.entries.removeValue(forKey: pid) }
            return
        }
        guard let process = resolve(pid) else {
            // The watch attached, so the process was alive: kept as unreadable (the safe default) until
            // its exit or exec fires the watch, so its later events post no new read. A process that
            // ended meanwhile fires the watch at once.
            state.withLock { $0.entries[pid] = .unreadable(watch: watch, cancel: cancel) }
            return
        }
        state.withLock { $0.entries[pid] = .read(process, watch: watch, cancel: cancel) }
    }

    /// On the queue: the process watch `watch` was armed for ended; its entry leaves.
    private func exited(_ pid: pid_t, watch: UInt64) {
        let cancel: (@Sendable () -> Void)? = state.withLock { state in
            let entry: (armed: UInt64, cancel: @Sendable () -> Void)
            switch state.entries[pid] {
            case let .read(_, armed, cancel), let .unreadable(armed, cancel): entry = (armed, cancel)
            case .reading, nil: return nil
            }
            guard entry.armed == watch else { return nil }
            state.entries[pid] = nil
            return entry.cancel
        }
        cancel?()
    }

    /// The kernel's answer: the start time, the path, and the start time again, so both name one process.
    static let system: Resolve = { pid in
        guard pid > 0, let start = startTime(pid), let path = AgentPanePersonInput.executablePath(pid), startTime(pid) == start else {
            return nil
        }
        return EventSourceProcess(start: start, path: path)
    }

    /// `sysctl(KERN_PROC_PID)`: public on every macOS the app runs on, with no same-user check (unlike
    /// `proc_pidinfo(PROC_PIDTBSDINFO)`, which refuses another user's process with EPERM). A pid with no
    /// process answers an empty record: nil.
    private static func startTime(_ pid: pid_t) -> UInt64? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride else {
            return nil
        }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return UInt64(clamping: start.tv_sec) &* 1_000_000 &+ UInt64(clamping: start.tv_usec)
    }

    /// The kernel's exit notice: a kqueue of its own with one `EVFILT_PROC` filter (`NOTE_EXIT | NOTE_EXEC`) on `pid`,
    /// registered with `EV_RECEIPT` so a refusal is seen here (nil), and read by a dispatch source on
    /// `queue`. A process that has already ended is refused with `ESRCH`.
    static let kernelExit: WatchExit = { pid, queue, exited in
        guard case let .success(descriptor) = exitQueue(pid) else { return nil }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            source.cancel()
            exited()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return { source.cancel() }
    }

    /// A kqueue holding one exit filter on `pid`, or the errno the kernel refused it with.
    static func exitQueue(_ pid: pid_t) -> Result<Int32, POSIXError> {
        let descriptor = kqueue()
        guard descriptor >= 0 else { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT | EV_RECEIPT),
                            fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXEC), data: 0, udata: nil)
        var receipt = kevent()
        // EV_RECEIPT: the call returns the registration's result at once and never waits for an event.
        let count = kevent(descriptor, &change, 1, &receipt, 1, nil)
        // Fail closed: only one receipt that says no error (EV_ERROR with data 0) is an attached watch.
        let error: Int32 = count < 0 ? errno : count == 1 && receipt.flags & UInt16(EV_ERROR) != 0 ? Int32(clamping: receipt.data) : EIO
        guard error == 0 else {
            close(descriptor)
            return .failure(POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL))
        }
        return .success(descriptor)
    }
}
