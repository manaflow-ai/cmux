/// The kind of wait a blocking call does, as the main-thread blocking detector names it.
///
/// The detector (``assertBlockingAllowed(_:fileID:line:)``) is cmux's copy of Chrome's
/// `base::ScopedBlockingCall` and `base::ThreadRestrictions`: the main thread never waits on
/// disk, a socket, another thread, another process or a child's exit
/// (plans/cmux-next/threading-model.md). The raw values are the names the debug log and the
/// opt-in hang reports use, so they never change.
public enum BlockingKind: String, Sendable, CaseIterable {
    /// A file system read, write, stat, directory listing or move.
    case fileIO = "file-io"
    /// A synchronous read or receive on a socket or pipe.
    case socketRead = "socket-read"
    /// A synchronous write or send on a socket or pipe (it waits while the peer's buffer is full).
    case socketWrite = "socket-write"
    /// A wait on a semaphore, a dispatch group, a condition or a `DispatchQueue.sync`.
    case syncWait = "sync-wait"
    /// A synchronous XPC or Mach send that waits for the reply.
    case ipcReply = "ipc-reply"
    /// A wait for a child process to exit.
    case processWait = "process-wait"
    /// Starting a child process (`Process.run`, `posix_spawn`, `fork`): it copies or maps the parent's
    /// address space and waits for the kernel, which took 807 ms on the main thread (screen.close,
    /// 2026-10-24).
    case processSpawn = "process-spawn"
    /// A ``Mutex`` wait on the main thread that took longer than
    /// ``BlockingKind/lockWaitLimitNanos`` (a contended lock: the priority-inversion case).
    case lockWait = "lock-wait"

    /// The longest contended ``Mutex`` wait the main thread may do before the detector records
    /// it (2 ms, lead decision 2026-10-24: a short critical section is allowed, as Chrome allows
    /// `base::Lock`; a wait this long means a lower-priority thread holds the lock).
    public static let lockWaitLimitNanos: UInt64 = 2_000_000
}
