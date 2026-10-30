import Darwin
import Dispatch

/// The process that posted a key or mouse event (`kCGEventSourceUnixProcessID`), as
/// ``EventSourceProcesses`` read it.
nonisolated struct EventSourceProcess: Equatable, Sendable {
    /// When the process started, in microseconds since 1970 (`pbi_start_tvsec`, `pbi_start_tvusec`):
    /// with the pid, it names one process, so a pid the kernel gives to a new process is a new one.
    var start: UInt64
    /// Its executable (`proc_pidpath`).
    var path: String
}

/// The executable path of each process that posts key and mouse events to the app, by pid, for
/// ``AgentPanePersonInput`` and ``PersonInputCheck``.
///
/// One table per app, built in the composition root (`AppServices.eventSources`) and passed through `init`;
/// tests build their own.
public nonisolated final class EventSourceProcesses: Sendable {
    /// Reads the process `pid` names now; nil when there is none. A system call: never on the main thread.
    typealias Resolve = @Sendable (pid_t) -> EventSourceProcess?
    /// Arms a watch for the exit of process `pid`: `exited` runs on `queue` once that process ends
    /// (at once when it has already ended). Returns the watch's cancel.
    typealias WatchExit = @Sendable (pid_t, DispatchQueue, @escaping @Sendable () -> Void) -> @Sendable () -> Void

    /// This process's pid, read once.
    static let ownPID = getpid()

    private let resolve: Resolve
    private let watchExit: WatchExit
    private let queue: DispatchQueue

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

    /// The executable path of the process `pid` names; nil when unknown. Reads the kernel on the caller's thread.
    func path(of pid: pid_t) -> String? {
        resolve(pid)?.path
    }

    /// The process the table holds for `pid` (tests and logs).
    func cached(_ pid: pid_t) -> EventSourceProcess? { nil }

    /// Returns once every read and exit queued before the call has been applied (tests).
    func settled() async {}

    /// The kernel's answer: the start time, the path, and the start time again, so both name one process.
    static let system: Resolve = { pid in
        guard pid > 0, let start = startTime(pid), let path = AgentPanePersonInput.executablePath(pid), startTime(pid) == start else {
            return nil
        }
        return EventSourceProcess(start: start, path: path)
    }

    private static func startTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // blocking-allow: the same read the person checks made per event before this seam; the next commit moves it onto the table's own queue
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    /// The kernel's exit notice (`EVFILT_PROC`, `NOTE_EXIT`) through a dispatch process source. libdispatch
    /// delivers the exit at once when the process has already ended (`ESRCH` at registration).
    static let kernelExit: WatchExit = { pid, queue, exited in
        // crash-allow: the source is only resumed here and cancelled through the returned closure; DispatchSource is thread-safe
        nonisolated(unsafe) let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { exited() }
        source.resume()
        return { source.cancel() }
    }
}
